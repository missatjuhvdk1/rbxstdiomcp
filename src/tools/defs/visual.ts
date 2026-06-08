import type { ToolDef } from '../types.js';
import { STILL_FRAME_NUDGE } from '../nudges.js';

const cameraAngleSchema = {
  description: 'Camera angle - use preset string or custom object with pitch/yaw/roll/distance',
  oneOf: [
    {
      type: 'string',
      enum: [
        'front',
        'back',
        'left',
        'right',
        'top',
        'bottom',
        'iso',
        'iso_front',
        'iso_back',
        'low_angle',
        'high_angle',
      ],
    },
    {
      type: 'object',
      properties: {
        pitch: { type: 'number', description: 'Pitch angle in degrees' },
        yaw: { type: 'number', description: 'Yaw angle in degrees' },
        roll: { type: 'number', description: 'Roll angle in degrees' },
        distance: { type: 'number', description: 'Camera distance from object' },
      },
    },
  ],
} as const;

/**
 * Visual feedback tools: viewport screenshot, off-screen ViewportFrame
 * render at any angle, and Studio camera focus (no image).
 */
export const visualTools: ToolDef[] = [
  {
    name: 'capture_screenshot',
    description:
      'Capture a screenshot of the current Roblox Studio viewport. Returns the image as base64-encoded RGBA pixel data. Use this to "see" what you\'ve built - GUIs, 3D objects, scene layout, etc. The screenshot captures exactly what\'s visible in the Studio viewport.',
    inputSchema: {
      type: 'object',
      properties: {
        maxWidth: {
          type: 'number',
          description: 'Maximum width of the returned image (default: 768). Smaller = faster + less data.',
          default: 768,
        },
        maxHeight: {
          type: 'number',
          description:
            'Maximum height of the returned image (default: 768). Smaller = faster + less data.',
          default: 768,
        },
      },
    },
    nudge: STILL_FRAME_NUDGE,
    handler: (args, { tools }) => tools.captureScreenshot(args?.maxWidth, args?.maxHeight),
  },

  {
    name: 'render_object_view',
    description: `Render a 3D object as an image from any angle using an off-screen ViewportFrame — the PRIMARY tool for visual feedback on what you've built. Works in ANY Studio state (Edit/Play/Run) with no CaptureService limits, and gives full control over camera, lighting, and background.

Angles: front, back, left, right, top, bottom, iso, iso_front, iso_back, low_angle, high_angle, or a custom {pitch, yaw, roll} in degrees.
Lighting presets: bright (3-point), studio (flat/even), dark (dramatic), default (ambient only).
For 2D GUIs use render_gui instead.`,
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Path to the object to render (e.g., "game.Workspace.Model1")',
        },
        angle: cameraAngleSchema,
        resolution: {
          type: 'object',
          properties: {
            width: { type: 'number', description: 'Image width (64-2048, default: 768)' },
            height: { type: 'number', description: 'Image height (64-2048, default: 768)' },
          },
          description: 'Render resolution',
        },
        lighting: {
          type: 'string',
          enum: ['default', 'bright', 'studio', 'dark', 'showcase', 'dramatic', 'flat'],
          description: 'Lighting preset to use (default: bright)',
        },
        background: {
          type: 'string',
          enum: ['transparent', 'grid', 'solid'],
          description: 'Background style (default: transparent)',
        },
        autoDistance: {
          type: 'boolean',
          description: 'Automatically calculate camera distance to fit object (default: true)',
        },
      },
      required: ['instancePath'],
    },
    nudge: STILL_FRAME_NUDGE,
    handler: (args, { tools }) =>
      tools.renderObjectView(args?.instancePath, {
        angle: args?.angle,
        resolution: args?.resolution,
        lighting: args?.lighting,
        background: args?.background,
        autoDistance: args?.autoDistance,
      }),
  },

  {
    name: 'render_gui',
    description: `Render a 2D GUI as an image — the visual-feedback tool for ScreenGuis, Frames, TextLabels, and other UI. render_object_view uses a ViewportFrame (3D only), so it cannot show UI; this captures a real on-screen rendering instead.

Pass any GUI by path (it doesn't have to live under StarterGui — e.g. "game.StarterGui.MainMenu", "game.StarterGui.HUD.HealthBar", or a ScreenGui you stored in ReplicatedStorage). Give a GuiObject (Frame, TextLabel, ImageLabel, …) to render that element, or a ScreenGui/SurfaceGui/BillboardGui to render all of its GuiObject children. Placement is faithful: elements are rendered inside a clone of their real ScreenGui (siblings, layout, and GUI inset intact), not repositioned to a corner.

region:
- "element" (default): crop tight to the element's on-screen rect — best for inspecting one component's visual correctness. Scale-based sizing renders at its real proportions.
- "screen": return the full viewport so you can verify WHERE the element actually lands (placement, overlaps, off-screen overflow) relative to the whole screen.

Optionally clamp the output with maxWidth/maxHeight (downscale only, aspect preserved).`,
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Path to the GUI to render (e.g. "game.StarterGui.MainMenu" or "game.StarterGui.HUD.HealthBar"). Any path works — not just StarterGui. Must be a GuiObject or a ScreenGui/SurfaceGui/BillboardGui.',
        },
        region: {
          type: 'string',
          enum: ['element', 'screen'],
          description:
            'Crop mode. "element" (default) crops tight to the GUI; "screen" returns the full viewport to check on-screen placement.',
          default: 'element',
        },
        maxWidth: {
          type: 'number',
          description: 'Optional max output width in pixels (downscale only, aspect preserved).',
        },
        maxHeight: {
          type: 'number',
          description: 'Optional max output height in pixels (downscale only, aspect preserved).',
        },
      },
      required: ['instancePath'],
    },
    nudge: STILL_FRAME_NUDGE,
    handler: (args, { tools }) =>
      tools.renderGui(args?.instancePath, {
        region: args?.region,
        maxWidth: args?.maxWidth,
        maxHeight: args?.maxHeight,
      }),
  },

  {
    name: 'focus_camera',
    description: `Point the Studio camera at an object (like pressing F), auto-fitting distance for any object size. Pairs with capture_screenshot: focus_camera then capture_screenshot.

Angles: front, back, left, right, top, bottom, iso (default), iso_front, iso_back, low_angle, high_angle, or custom {pitch, yaw, roll}. Distance auto-fits from tiny (clamped to ~5 studs) to huge (1000+ studs) objects; override with \`distance\`.`,
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Path to the object to focus on (e.g., "game.Workspace.Model1")',
        },
        angle: {
          description: 'Camera angle - preset string or custom {pitch, yaw, roll}',
          oneOf: [
            {
              type: 'string',
              enum: [
                'front',
                'back',
                'left',
                'right',
                'top',
                'bottom',
                'iso',
                'iso_front',
                'iso_back',
                'low_angle',
                'high_angle',
              ],
            },
            {
              type: 'object',
              properties: {
                pitch: { type: 'number', description: 'Pitch angle in degrees' },
                yaw: { type: 'number', description: 'Yaw angle in degrees' },
                roll: { type: 'number', description: 'Roll angle in degrees' },
              },
            },
          ],
        },
        distance: {
          type: 'number',
          description: 'Manual camera distance (overrides auto-distance)',
        },
        autoDistance: {
          type: 'boolean',
          description: 'Automatically calculate distance to fit object (default: true)',
        },
      },
      required: ['instancePath'],
    },
    handler: (args, { tools }) =>
      tools.focusCamera(args?.instancePath, {
        angle: args?.angle,
        distance: args?.distance,
        autoDistance: args?.autoDistance,
      }),
  },
];
