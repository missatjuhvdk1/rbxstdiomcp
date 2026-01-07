/**
 * TypeScript Integration for ViewportFrame Rendering System
 * Add these methods to src/tools/index.ts in the RobloxStudioTools class
 */

// ============================================
// Add to RobloxStudioTools class
// ============================================

/**
 * render_object_view - Render an object from any angle using ViewportFrame
 * This is the PRIMARY visual feedback tool for AI
 */
async renderObjectView(
  instancePath: string,
  options?: {
    angle?: string | { pitch?: number; yaw?: number; roll?: number; distance?: number };
    resolution?: { width?: number; height?: number };
    lighting?: 'default' | 'bright' | 'studio' | 'dark' | 'showcase' | 'dramatic' | 'flat';
    background?: 'transparent' | 'grid' | 'solid';
    autoDistance?: boolean;
  }
) {
  if (!instancePath) {
    throw new Error('Instance path is required for render_object_view');
  }

  const response = await this.client.request('/api/render-object-view', {
    instancePath,
    angle: options?.angle || 'iso',
    resolution: options?.resolution || { width: 512, height: 512 },
    lighting: options?.lighting || 'bright',
    background: options?.background || 'transparent',
    autoDistance: options?.autoDistance !== false,
  });

  // Convert RGBA to PNG (same as captureScreenshot)
  const responseData = response as any;
  if (responseData.success && responseData.base64) {
    try {
      const rgbaBuffer = Buffer.from(responseData.base64, 'base64');
      const width = responseData.width;
      const height = responseData.height;

      // Validate buffer size
      const expectedSize = width * height * 4;
      if (rgbaBuffer.length !== expectedSize) {
        throw new Error(
          `Buffer size mismatch: got ${rgbaBuffer.length}, expected ${expectedSize}`
        );
      }

      // Convert RGBA to PNG (using existing createPNG utility)
      const pngBuffer = createPNG(rgbaBuffer, width, height);
      const pngBase64 = pngBuffer.toString('base64');

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                success: true,
                message: responseData.message,
                viewInfo: responseData.viewInfo,
                format: 'PNG',
              },
              null,
              2
            ),
          },
          {
            type: 'image',
            data: pngBase64,
            mimeType: 'image/png',
          },
        ],
      };
    } catch (err) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                success: false,
                error: `PNG conversion failed: ${err instanceof Error ? err.message : String(err)}`,
              },
              null,
              2
            ),
          },
        ],
      };
    }
  }

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(response, null, 2),
      },
    ],
  };
}

/**
 * render_multi_view - Render object from multiple angles at once
 */
async renderMultiView(
  instancePath: string,
  options?: {
    angles?: string[];
    resolution?: { width?: number; height?: number };
    lighting?: string;
    background?: string;
  }
) {
  if (!instancePath) {
    throw new Error('Instance path is required for render_multi_view');
  }

  const response = await this.client.request('/api/render-multi-view', {
    instancePath,
    angles: options?.angles || ['front', 'iso', 'top'],
    resolution: options?.resolution || { width: 256, height: 256 },
    lighting: options?.lighting || 'bright',
    background: options?.background || 'transparent',
  });

  const responseData = response as any;
  if (responseData.success && responseData.views) {
    const content: any[] = [
      {
        type: 'text',
        text: JSON.stringify(
          {
            success: true,
            message: responseData.message,
            viewCount: responseData.count,
          },
          null,
          2
        ),
      },
    ];

    // Convert each view to PNG and add as image
    for (const view of responseData.views) {
      try {
        const rgbaBuffer = Buffer.from(view.base64, 'base64');
        const pngBuffer = createPNG(rgbaBuffer, view.width, view.height);
        const pngBase64 = pngBuffer.toString('base64');

        content.push({
          type: 'image',
          data: pngBase64,
          mimeType: 'image/png',
        });
      } catch (err) {
        // Skip failed conversions
      }
    }

    return { content };
  }

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(response, null, 2),
      },
    ],
  };
}

/**
 * set_camera_view - Control Studio camera position and angle
 */
async setCameraView(
  target: string | { x: number; y: number; z: number },
  options?: {
    distance?: number;
    angle?: 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
    smooth?: boolean;
  }
) {
  const response = await this.client.request('/api/set-camera-view', {
    target,
    distance: options?.distance || 10,
    angle: options?.angle || 'iso',
    smooth: options?.smooth !== false,
  });

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(response, null, 2),
      },
    ],
  };
}

/**
 * focus_selection - Like pressing F in Studio
 */
async focusSelection(instancePaths?: string[]) {
  const response = await this.client.request('/api/focus-selection', {
    instancePaths: instancePaths || [],
  });

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(response, null, 2),
      },
    ],
  };
}

// ============================================
// Add to MCP Tool Definitions (src/index.ts)
// ============================================

/**
 * Add these tool definitions to the server.setRequestHandler callback
 */

// Render Object View Tool
{
  name: 'render_object_view',
  description: `Render an object as an image from any angle using ViewportFrame.
    This is the PRIMARY tool for visual feedback - use it whenever you need to "see" what you've created.

    Works in ANY Studio state (Edit/Play/Run) - no CaptureService limitations!
    Instant rendering with full control over camera, lighting, and background.

    Use cases:
    - Verify visual appearance of created objects
    - Generate thumbnails/previews
    - Debug positioning and orientation
    - Iterate on visual designs
    - Document objects with images`,
  inputSchema: {
    type: 'object',
    properties: {
      instancePath: {
        type: 'string',
        description: 'Path to the object to render (e.g., "game.Workspace.Model1")',
      },
      angle: {
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
            description: 'Camera angle preset',
          },
          {
            type: 'object',
            properties: {
              pitch: { type: 'number', description: 'Pitch angle in degrees' },
              yaw: { type: 'number', description: 'Yaw angle in degrees' },
              roll: { type: 'number', description: 'Roll angle in degrees' },
              distance: { type: 'number', description: 'Camera distance from object' },
            },
            description: 'Custom camera angle',
          },
        ],
        description: 'Camera angle - use preset or custom angles',
      },
      resolution: {
        type: 'object',
        properties: {
          width: { type: 'number', description: 'Image width (64-2048)' },
          height: { type: 'number', description: 'Image height (64-2048)' },
        },
        description: 'Render resolution (default: 512x512)',
      },
      lighting: {
        type: 'string',
        enum: ['default', 'bright', 'studio', 'dark', 'showcase', 'dramatic', 'flat'],
        description: 'Lighting preset to use',
      },
      background: {
        type: 'string',
        enum: ['transparent', 'grid', 'solid'],
        description: 'Background style',
      },
      autoDistance: {
        type: 'boolean',
        description: 'Automatically calculate camera distance to fit object (default: true)',
      },
    },
    required: ['instancePath'],
  },
}

// Render Multi View Tool
{
  name: 'render_multi_view',
  description: `Render an object from multiple angles at once.
    Returns a grid of images showing different perspectives.
    Perfect for comprehensive visual documentation.`,
  inputSchema: {
    type: 'object',
    properties: {
      instancePath: {
        type: 'string',
        description: 'Path to the object to render',
      },
      angles: {
        type: 'array',
        items: { type: 'string' },
        description: 'Array of angle presets (default: ["front", "iso", "top"])',
      },
      resolution: {
        type: 'object',
        properties: {
          width: { type: 'number' },
          height: { type: 'number' },
        },
        description: 'Resolution for each view (default: 256x256)',
      },
      lighting: {
        type: 'string',
        description: 'Lighting preset',
      },
      background: {
        type: 'string',
        description: 'Background style',
      },
    },
    required: ['instancePath'],
  },
}

// Set Camera View Tool
{
  name: 'set_camera_view',
  description: `Control the Studio camera position and angle.
    Useful for setting up a view before taking a screenshot or just navigating the viewport.`,
  inputSchema: {
    type: 'object',
    properties: {
      target: {
        oneOf: [
          { type: 'string', description: 'Instance path to focus on' },
          {
            type: 'object',
            properties: {
              x: { type: 'number' },
              y: { type: 'number' },
              z: { type: 'number' },
            },
            description: 'Vector3 position to look at',
          },
        ],
        description: 'What to focus the camera on',
      },
      distance: {
        type: 'number',
        description: 'Distance from target (default: 10)',
      },
      angle: {
        type: 'string',
        enum: ['front', 'back', 'left', 'right', 'top', 'bottom', 'iso'],
        description: 'Camera angle preset',
      },
      smooth: {
        type: 'boolean',
        description: 'Smooth camera transition (default: true)',
      },
    },
    required: ['target'],
  },
}

// Focus Selection Tool
{
  name: 'focus_selection',
  description: `Focus the Studio camera on specific objects (like pressing F).
    If no paths provided, focuses on current selection.`,
  inputSchema: {
    type: 'object',
    properties: {
      instancePaths: {
        type: 'array',
        items: { type: 'string' },
        description: 'Paths to objects to focus on (optional)',
      },
    },
  },
}

// ============================================
// Example AI Usage Patterns
// ============================================

/*

BEFORE (limited visual feedback):
---
User: "Create a sword tool"
AI: *creates sword*
AI: "Created sword at game.Workspace.Sword"
User: "What does it look like?"
AI: *can't answer without screenshot, which may fail in play mode*

AFTER (with viewport rendering):
---
User: "Create a sword tool"
AI: *creates sword*
AI: *calls render_object_view*
AI: "Created sword at game.Workspace.Sword. Here's what it looks like:"
[Shows isometric render of sword]
AI: "The blade is 3 studs long, handle is 1 stud. Would you like me to adjust the proportions?"

---

User: "Show me my character in first person view"
AI: *calls render_object_view with custom camera angle*
AI: "Here's your character from a first-person perspective:"
[Shows render with camera at head height looking forward]

---

User: "Create a building and show me all sides"
AI: *creates building*
AI: *calls render_multi_view*
AI: "Here's your building from multiple angles:"
[Shows front, back, left, right, top, iso views in a grid]

*/

// ============================================
// Performance Notes
// ============================================

/*

Viewport rendering is FAST:
- No async callbacks (unlike CaptureScreenshot)
- Renders in ~100ms typically
- Works in any Studio state
- No HTTP request/response delay
- Can render objects not in current view

Memory usage:
- Viewport + WorldModel + Camera ≈ 1MB
- EditableImage for 512x512 ≈ 1MB
- Total per render: ~2-3MB
- Cleanup happens automatically

Recommendations:
- Use 512x512 for single detailed views
- Use 256x256 for multi-view grids
- Use 1024x1024+ for high-quality showcases
- Avoid rendering massive models (>10k parts) at high res

*/
