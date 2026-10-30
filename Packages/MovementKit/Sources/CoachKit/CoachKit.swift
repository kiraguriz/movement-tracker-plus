// Muse client (through the proxy): request builders, schemas, tools, streaming, cache and offline fallbacks.
//
// Layers, bottom up:
//   Core/       JSONValue (canonical encoding, partial parsing), schema builder/checker/validator, errors, locale.
//   Transport/  HTTP transport, clock and retry policy, token store, SSE parser, Responses API model.
//   CoachClient the actor that talks to the proxy: install token, retries, streaming.
//   Insights/   set review, session debrief and meal photo: prompts, schemas, cache, retry-on-schema-failure, offline fallback.
//   Chat/       coach chat with on-device tools, proposals, history budget and ChatStore status handling.
//
// Muse never counts reps: every prompt tells the model that the numbers were measured on the device.

/// Bumped when a change to this module alters what is sent to the proxy or how answers are stored.
public enum CoachKitInfo {
    public static let version = "1"
}
