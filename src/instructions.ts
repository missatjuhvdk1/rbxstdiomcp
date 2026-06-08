/**
 * Server-level `instructions` — the always-on operating manual returned in the
 * MCP `initialize` response. Clients typically fold this into the system prompt.
 *
 * This is the ONE place we pay always-on tokens deliberately, so it earns its
 * keep by carrying what individual tool descriptions cannot: the overall mental
 * model and the cross-tool workflow. Per MCP guidance it must NOT duplicate tool
 * descriptions (those are already in front of the model) — keep it about
 * relationships, sequencing, and the core operating principle.
 *
 * The same principle is reinforced just-in-time by `src/tools/nudges.ts`, which
 * fires only when the relevant tools are actually called.
 */
export const SERVER_INSTRUCTIONS = `This server drives a live Roblox Studio session through a bridge plugin. Unless a play test is running you are in Edit mode (the open place file), so changes you make are edits to the project, not to a running game.

Core principle — instrument, don't spectate. You can mutate the world and read back facts, but you cannot perceive motion, timing, input feel, or sound. For anything dynamic or subjective, INSTRUMENT it (event-keyed debug prints, on-screen readouts, attribute mirroring, visual markers) and hand the test to the user with a short test card: do X -> watch for Y -> paste Z back. Treat play tests and screenshots as smoke checks — they confirm the game boots and surface errors/tracebacks; they are not how you decide whether behavior is correct. Do not loop play-tests or screenshots trying to judge feel.

Typical flow:
- Locate things with grep (it searches script Source and instance names) before browsing get_project_structure.
- Verify the engine API with search_roblox_docs / get_roblox_api_reference instead of guessing property and method names.
- Edit scripts with targeted edit_script / find_and_replace_in_scripts rather than rewriting whole files with set_script_source.
- execute_lua runs in Edit mode as a single undoable waypoint (keep its mutations synchronous so undo captures them); run_live_lua runs inside a play test (start one with play_solo first).
- See results with render_object_view (3D objects), render_gui (2D UI), or capture_screenshot paired with focus_camera — all are still frames.

Prefer small, verifiable steps; report what you changed and let the user drive any test that needs human judgment.`;
