# Bridge extensions

BookKit's bridge is an extension boundary for trusted host-app code that needs
access to the rendered DOM. Typical uses include text-to-speech focus, custom
selection tools, reading telemetry, domain-specific annotations, and host UI that
must stay synchronized with visible content.

Publication code is not a plug-in. BookKit sanitizes publication markup, disables
publication JavaScript by default, and installs its runtime and host plug-ins in
`WKContentWorld.defaultClient`.

## Runtime model

The built-in runtime and every `ReflowScriptPlugin`:

- share the same isolated app content world;
- can read and modify the rendered publication DOM;
- cannot be read or replaced by scripts in the page world;
- remain installed while BookKit replaces chapter content in the same document;
- communicate with Swift only through typed commands and events.

Plug-ins are trusted application code. Do not install scripts from an ebook or an
untrusted network response.

## Installing a plug-in

```swift
import BookKit

let speechPlugin = ReflowScriptPlugin(
    identifier: "com.example.reader.speech",
    source: """
    window.BookKit.registerCommand('speech.focus', payload => {
      const target = document.getElementById(payload.anchor);
      target?.scrollIntoView({ block: 'center' });
      return { found: Boolean(target), anchor: payload.anchor };
    });

    window.BookKit.on('selectionChanged', selection => {
      window.BookKit.post('speech.selection', selection);
    });
    """
)

let reader = try await BookReader.open(
    from: fileURL,
    configuration: .init(plugins: [speechPlugin])
)
```

`identifier` identifies the plug-in to the host. Command and event names are not
automatically prefixed, so use a stable namespace such as `speech.*` or
`com.example.feature.*`.

## App-to-JavaScript commands

Register a command once when the plug-in script runs:

```javascript
window.BookKit.registerCommand('speech.focus', async payload => {
  const target = document.getElementById(payload.anchor);
  target?.scrollIntoView();
  return {
    anchor: payload.anchor,
    focused: Boolean(target)
  };
});
```

Call it from the reader:

```swift
let result = try await reader.callBridgeCommand(
    "speech.focus",
    payload: .object([
        "anchor": .string("paragraph-12")
    ])
)
```

Command handlers may be synchronous or asynchronous. Their return value is
converted into `BridgeValue`. Calling an unknown command or throwing inside a
handler fails the Swift call.

Command names must be non-empty and unique within the bridge. Registering the same
name twice throws in JavaScript.

## JavaScript-to-app events

Post a custom event from a plug-in:

```javascript
window.BookKit.post('speech.state', {
  state: 'speaking',
  anchor: 'paragraph-12'
});
```

Receive it through the normal navigator stream:

```swift
let events = renderer.events

Task { @MainActor in
    for await event in events {
        guard case let .bridgeMessage(name, payload) = event else {
            continue
        }

        if name == "speech.state" {
            handleSpeechState(payload)
        }
    }
}
```

Every event subscriber receives its own buffered stream; a telemetry consumer does
not steal events from UI state handling.

## Bridge values

`BridgeValue` is a recursive JSON-shaped value:

```swift
public indirect enum BridgeValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BridgeValue])
    case object([String: BridgeValue])
}
```

Use only values representable by that model. DOM nodes, functions, symbols,
cyclic objects, and other JavaScript-only values cannot cross the boundary.

## Lifecycle hooks

Subscribe with `BookKit.on`. It returns a function that removes that handler.

```javascript
const stop = window.BookKit.on('positionChanged', position => {
  // position.progression and position.anchor
});

// Later, if the plug-in no longer needs the callback:
stop();
```

Available hooks:

| Hook | Payload |
| --- | --- |
| `contentWillChange` | `{ viewport: { width, height } }` before body replacement |
| `contentDidChange` | `{ viewport: { width, height } }` after the new body is installed |
| `positionChanged` | `{ progression, anchor }` after visible position changes |
| `selectionChanged` | `{ start, end, text }` for non-empty selections |
| `linkTapped` | `{ url, kind }` before the native link policy handles the action |

An exception in a lifecycle handler does not stop other handlers. BookKit reports
it as a custom `bookkit.pluginError` event with the hook name and error message.

## DOM ownership

`setContent` replaces `document.body.innerHTML` when the host renders another
section. Plug-ins should therefore:

- install long-lived hooks at script load time;
- query chapter elements after `contentDidChange`;
- avoid retaining detached DOM nodes across content changes;
- use stable publication anchors where available;
- keep per-chapter observers disposable.

The bridge emits high-frequency position updates at most once per animation frame
and suppresses duplicate progression/anchor pairs. Explicit navigation commands
still emit a deterministic position update.

## Link handling

BookKit intercepts every publication anchor click and prevents WebKit's default
navigation. The click becomes a native bridge event, then `BookReader` applies
the configured `LinkPolicy`.

Do not add a plug-in click handler that performs navigation independently. Use the
`linkTapped` lifecycle hook for observation and the native `LinkPolicy` for the
decision so WebKit and the navigator cannot race.

## Versioning recommendations

- Namespace command and event names.
- Include a schema version in payloads that will persist or cross app versions.
- Treat command failure as recoverable and surface it through app state.
- Keep plug-ins small; move business logic and persistence to Swift.
- Add a `WebViewReflowBridgeTests` integration test for every public command or
  lifecycle contract.
