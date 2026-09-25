#if canImport(WebKit)
    extension WebViewReflowBridge {
        /// Runs in the same isolated scope as the bridge bootstrap.
        static let textSupportScript = #"""
              const textBlocks = new Set('address article aside blockquote br dd div dl dt figcaption figure footer h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section table td th tr ul'.split(' '));
              const textExcluded = new Set('script style head template noscript'.split(' '));
              const textWhitespace = /[\t\n\f\r \u00a0]/;
              const textMap = () => {
                const nodes = [], chunks = [];
                let length = 0;
                const append = value => { chunks.push(value); length += value.length; };
                const stack = [[document.body, false]];
                while (stack.length) {
                  const [node, closing] = stack.pop();
                  if (!node) continue;
                  if (node.nodeType === Node.TEXT_NODE) {
                    nodes.push({ node, start: length, end: length + node.data.length });
                    append(node.data);
                  } else if (node.nodeType === Node.ELEMENT_NODE) {
                    const tag = node.localName.toLowerCase();
                    if (closing) { if (textBlocks.has(tag)) append(' '); continue; }
                    if (node.id === 'bookkit-position-announcer') continue;
            if (textExcluded.has(tag) || node.hidden || node.getAttribute('aria-hidden') === 'true') continue;
                    const style = window.getComputedStyle(node);
                    if (style.display === 'none' || style.visibility === 'hidden') continue;
                    if (textBlocks.has(tag)) append(' ');
                    if (!closing) {
                      stack.push([node, true]);
                      for (let i = node.childNodes.length - 1; i >= 0; i--) stack.push([node.childNodes[i], false]);
                    }
                  }
                }
                const raw = chunks.join('');
                const offsets = new Uint32Array(raw.length);
                const parts = [];
                let count = 0, pendingSpace = -1;
                for (let i = 0; i < raw.length;) {
                  if (textWhitespace.test(raw[i])) {
                    if (pendingSpace < 0) pendingSpace = i;
                    i++;
                  } else {
                    if (count && pendingSpace >= 0) { parts.push(' '); offsets[count++] = pendingSpace; }
                    pendingSpace = -1;
                    const start = i;
                    while (i < raw.length && !textWhitespace.test(raw[i])) { offsets[count++] = i++; }
                    parts.push(raw.slice(start, i));
                  }
                }
                return { text: parts.join(''), offsets: offsets.subarray(0, count), nodes };
              };
              window.BookKitNativeTextMap = textMap;

              const textLocation = (map, start, end) => {
                let prefixStart = Math.max(0, start - 32), suffixEnd = Math.min(map.text.length, end + 32);
                const lowSurrogate = offset => { const code = map.text.charCodeAt(offset); return code >= 0xDC00 && code <= 0xDFFF; };
                if (prefixStart < start && lowSurrogate(prefixStart)) prefixStart++;
                if (suffixEnd < map.text.length && suffixEnd > end && lowSurrogate(suffixEnd)) suffixEnd--;
                return { start, end, quote: map.text.slice(start, end),
                  prefix: map.text.slice(prefixStart, start), suffix: map.text.slice(end, suffixEnd) };
              };
              const lowerBound = (array, value) => {
                let lo = 0, hi = array.length;
                while (lo < hi) { const mid = lo + Math.floor((hi - lo) / 2); if (array[mid] < value) lo = mid + 1; else hi = mid; }
                return lo;
              };
              const domPoint = (map, raw, isEnd) => {
                for (let i = 0; i < map.nodes.length; i++) {
                  const item = map.nodes[i];
                  if (raw < item.end || (isEnd && raw === item.end)) return [item.node, Math.max(0, raw - item.start)];
                }
                const last = map.nodes[map.nodes.length - 1];
                return last ? [last.node, last.node.data.length] : null;
              };
              const domRange = (map, start, end) => {
                if (!(start >= 0 && end > start && end <= map.text.length)) return null;
                const a = domPoint(map, map.offsets[start], false);
                const b = domPoint(map, map.offsets[end - 1] + 1, true);
                if (!a || !b) return null;
                const range = document.createRange();
                range.setStart(...a); range.setEnd(...b);
                return range;
              };
              const resolveText = (target, map) => {
                if (!target || typeof target.quote !== 'string' || !target.quote.length) return null;
                const { quote, prefix = '', suffix = '' } = target;
                const matchesContext = start => (!prefix || map.text.slice(Math.max(0, start - prefix.length), start) === prefix)
                  && (!suffix || map.text.slice(start + quote.length, start + quote.length + suffix.length) === suffix);
                if (Number.isSafeInteger(target.start) && Number.isSafeInteger(target.end) && target.start >= 0
                    && map.text.slice(target.start, target.end) === quote && matchesContext(target.start)) {
                  return { start: target.start, end: target.end };
                }
                let found = -1, best = -1, tied = false;
                for (let start = map.text.indexOf(quote); start >= 0; start = map.text.indexOf(quote, start + 1)) {
                  let score = 0;
                  for (let n = 1; n <= prefix.length && start >= n; n++) {
                    if (map.text[start - n] !== prefix[prefix.length - n]) break;
                    score++;
                  }
                  for (let n = 0; n < suffix.length && start + quote.length + n < map.text.length; n++) {
                    if (map.text[start + quote.length + n] !== suffix[n]) break;
                    score++;
                  }
                  if (score > best) { found = start; best = score; tied = false; }
                  else if (score === best) tied = true;
                }
                return found >= 0 && !tied ? { start: found, end: found + quote.length } : null;
              };
              window.BookKitNativeResolveText = target => {
                const map = textMap(), found = resolveText(target, map);
                return found ? domRange(map, found.start, found.end) : null;
              };
              window.BookKitNativeGoToText = target => {
                const range = window.BookKitNativeResolveText(target);
                if (!range) return null;
                const rect = range.getBoundingClientRect();
                // Use the current layout's scroll axis, without changing the selection.
                if (rect.top >= 0 && rect.bottom <= innerHeight && rect.left >= 0 && rect.right <= innerWidth) {
                  return { progression: computeProgression() };
                }
                if (window.__bookkitReadingMode === 'paginated') {
                  const width = Math.max(window.innerWidth, 1);
                  window.BookKitNativeScrollTo(Math.floor((rect.left + window.scrollX) / width) * width, 0);
                } else window.BookKitNativeScrollTo(window.scrollX, rect.top + window.scrollY);
                window.BookKitNativeReportPosition(true);
                return { progression: computeProgression() };
              };
              window.BookKitNativeClearSelection = () => {
                window.getSelection()?.removeAllRanges();
                post({ type: 'selectionCleared' });
              };

              // Wrapping text works on all supported OS versions and preserves semantic elements.
              // A single interval pass supports overlapping groups without changing publisher styles.
              const clearTextDecorations = () => {
                const parents = new Set();
                document.querySelectorAll('[data-bookkit-text-mark]').forEach(mark => {
                  const parent = mark.parentNode;
                  if (!parent || !mark.__bookkitMarks) return;
                  parents.add(parent);
                  mark.replaceWith(...mark.childNodes);
                });
                parents.forEach(parent => parent.normalize());
              };
              window.BookKitNativeApplyTextDecorations = decorations => {
                const savedSelection = captureSelection();
                clearTextDecorations();
                if (!decorations.length && !savedSelection) return;
                const map = textMap();
                const ranges = [];
                for (let order = 0; order < decorations.length; order++) {
                  const decoration = decorations[order];
                  let found = resolveText(decoration.locator?.textRange, map);
                  if (!found && !decoration.locator?.textRange && decoration.locator?.anchor) {
                    const target = document.getElementById(decoration.locator.anchor);
                    const contained = map.nodes.filter(item => target?.contains(item.node));
                    if (contained.length) found = {
                      start: lowerBound(map.offsets, contained[0].start),
                      end: lowerBound(map.offsets, contained[contained.length - 1].end)
                    };
                  }
                  if (found && found.end > found.start) ranges.push({
                    start: map.offsets[found.start], end: map.offsets[found.end - 1] + 1, decoration, order
                  });
                }
                ranges.sort((a, b) => a.start - b.start || a.order - b.order);
                let nextRange = 0, activeRanges = [];
                for (const item of map.nodes) {
                  activeRanges = activeRanges.filter(range => range.end > item.start);
                  while (nextRange < ranges.length && ranges[nextRange].start < item.end) {
                    const range = ranges[nextRange++];
                    if (range.end > item.start) activeRanges.push(range);
                  }
                  const intervals = [];
                  for (const match of activeRanges) {
                    const start = Math.max(item.start, match.start);
                    const end = Math.min(item.end, match.end);
                    if (end > start) intervals.push({ start: start - item.start, end: end - item.start, decoration: match.decoration, order: match.order });
                  }
                  intervals.sort((a, b) => a.order - b.order);
                  if (!intervals.length) continue;
                  const cuts = [...new Set([0, item.node.data.length, ...intervals.flatMap(i => [i.start, i.end])])].sort((a, b) => a - b);
                  const fragment = document.createDocumentFragment();
                  for (let i = 0; i < cuts.length - 1; i++) {
                    const text = document.createTextNode(item.node.data.slice(cuts[i], cuts[i + 1]));
                    const active = intervals.filter(interval => interval.start <= cuts[i] && interval.end >= cuts[i + 1]);
                    if (!active.length) { fragment.appendChild(text); continue; }
                    const mark = document.createElement('span');
                    mark.setAttribute('data-bookkit-text-mark', '');
                    mark.__bookkitMarks = active.map(item => item.decoration);
                    if (mark.__bookkitMarks.some(item => item.group === 'highlight')) {
                      mark.setAttribute('role', 'button');
                      mark.tabIndex = 0;
                    }
                    for (const { decoration } of active) {
                      const style = decoration.style || {};
                      if (style.backgroundColor) mark.style.setProperty('background-color', style.backgroundColor, 'important');
                      if (style.textColor) {
                        mark.style.setProperty('color', style.textColor, 'important');
                        mark.style.setProperty('-webkit-text-fill-color', style.textColor, 'important');
                      }
                      if (style.underlineColor) { mark.style.textDecoration = 'underline'; mark.style.textDecorationColor = style.underlineColor; }
                    }
                    mark.appendChild(text); fragment.appendChild(mark);
                  }
                  item.node.replaceWith(fragment);
                }
                if (savedSelection) {
                  const restored = window.BookKitNativeResolveText(savedSelection.target);
                  if (restored) {
                    const selection = window.getSelection();
                    selection.removeAllRanges(); selection.addRange(restored);
                  }
                }
              };
              const captureSelection = () => {
                const selection = window.getSelection();
                if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
                const range = selection.getRangeAt(0), map = textMap();
                let rawStart = null, rawEnd = null;
                for (const item of map.nodes) {
                  if (!range.intersectsNode(item.node)) continue;
                  const start = range.startContainer === item.node ? range.startOffset : 0;
                  const end = range.endContainer === item.node ? range.endOffset : item.node.data.length;
                  if (end <= start) continue;
                  if (rawStart === null) rawStart = item.start + start;
                  rawEnd = item.start + end;
                }
                if (rawStart === null) return null;
                let start = lowerBound(map.offsets, rawStart), end = lowerBound(map.offsets, rawEnd);
                while (start < end && map.text[start] === ' ') start++;
                while (end > start && map.text[end - 1] === ' ') end--;
                if (end <= start) return null;
                const rect = range.getBoundingClientRect();
                return { target: textLocation(map, start, end), bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
              };
              document.addEventListener('selectionchange', () => {
                const saved = captureSelection();
                if (!saved) { post({ type: 'selectionCleared' }); return; }
                const target = saved.target;
                const payload = { type: 'selectionChanged', start: target.start, end: target.end, text: target.quote,
                  prefix: target.prefix, suffix: target.suffix, bounds: saved.bounds };
                post(payload);
                window.BookKitNativeEmitHook('selectionChanged', payload);
              });
            """#
    }
#endif
