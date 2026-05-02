import type { ToolDef } from '../types.js';

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
    handler: (args, { tools }) => tools.captureScreenshot(args?.maxWidth, args?.maxHeight),
  },

  {
    name: 'render_object_view',
    description: `Render an object as an image from any angle using ViewportFrame. This is the PRIMARY tool for visual feedback - use it whenever you need to "see" what you've created or verify visual appearance.

Works in ANY Studio state (Edit/Play/Run) - no CaptureService limitations!
Instant rendering with full control over camera, lighting, and background.

Use cases:
- Verify visual appearance of created objects
- Generate thumbnails/previews
- Debug positioning and orientation
- Iterate on visual designs
- Show users what their objects look like

Available camera angles: front, back, left, right, top, bottom, iso (isometric), iso_front, iso_back, low_angle, high_angle
Or provide custom angles with pitch/yaw/roll in degrees.

Lighting presets: bright (3-point lighting), studio (flat/even), dark (dramatic), default (ambient only)`,
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
    name: 'focus_camera',
    description: `Position the Studio camera to focus on an object (like pressing F in Studio).
Automatically calculates distance to fit the object in view, works with any object size.

Perfect combo with capture_screenshot:
1. focus_camera({instancePath: "...", angle: "front"})
2. capture_screenshot()

Supported angles:
- Standard views: front, back, left, right, top, bottom
- Isometric: iso (default), iso_front, iso_back
- Dramatic: low_angle, high_angle
- Custom: {pitch: 30, yaw: 45, roll: 0}

Auto-sizing:
- Tiny objects (0.1 studs): Camera backs up to minimum 5 studs
- Normal objects (10 studs): Camera positioned perfectly
- Huge objects (1000 studs): Camera backs up far enough to see everything`,
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
