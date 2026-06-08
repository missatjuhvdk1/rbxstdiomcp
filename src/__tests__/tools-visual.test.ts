import { BridgeService } from '../bridge-service';
import { RobloxStudioTools } from '../tools/index';
import { parseToolText } from './helpers';

function setup(response: any) {
  const bridge = {
    sendRequest: jest.fn().mockResolvedValue(response),
  } as unknown as BridgeService;
  return new RobloxStudioTools(bridge);
}

function onePixelRgbaBase64() {
  return Buffer.from([255, 0, 0, 255]).toString('base64');
}

describe('visual tool PNG conversion', () => {
  test('captureScreenshot converts RGBA payloads to PNG image content', async () => {
    const tools = setup({
      success: true,
      message: 'captured',
      originalWidth: 1,
      originalHeight: 1,
      width: 1,
      height: 1,
      base64: onePixelRgbaBase64(),
    });

    const result = await tools.captureScreenshot(1, 1);
    const body = parseToolText(result);

    expect(body).toMatchObject({
      success: true,
      message: 'captured',
      width: 1,
      height: 1,
      format: 'PNG',
    });
    expect(result.content[1]).toMatchObject({
      type: 'image',
      mimeType: 'image/png',
    });
    expect(result.content[1].data).toMatch(/^iVBORw0KGgo/);
  });

  test('renderObjectView converts RGBA payloads to PNG image content', async () => {
    const tools = setup({
      success: true,
      message: 'rendered',
      viewInfo: { angle: 'iso' },
      width: 1,
      height: 1,
      base64: onePixelRgbaBase64(),
    });

    const result = await tools.renderObjectView('game.Workspace.Part');
    const body = parseToolText(result);

    expect(body).toMatchObject({
      success: true,
      message: 'rendered',
      viewInfo: { angle: 'iso' },
      format: 'PNG',
    });
    expect(result.content[1]).toMatchObject({
      type: 'image',
      mimeType: 'image/png',
    });
    expect(result.content[1].data).toMatch(/^iVBORw0KGgo/);
  });

  test('renderGui converts RGBA payloads to PNG image content', async () => {
    const tools = setup({
      success: true,
      message: 'rendered gui',
      guiInfo: { objectClass: 'ScreenGui', renderedElements: 2 },
      width: 1,
      height: 1,
      base64: onePixelRgbaBase64(),
    });

    const result = await tools.renderGui('game.StarterGui.MainMenu');
    const body = parseToolText(result);

    expect(body).toMatchObject({
      success: true,
      message: 'rendered gui',
      guiInfo: { objectClass: 'ScreenGui', renderedElements: 2 },
      format: 'PNG',
    });
    expect(result.content[1]).toMatchObject({
      type: 'image',
      mimeType: 'image/png',
    });
    expect(result.content[1].data).toMatch(/^iVBORw0KGgo/);
  });

  test('renderGui returns a structured conversion error for bad buffers', async () => {
    const tools = setup({
      success: true,
      width: 2,
      height: 2,
      base64: onePixelRgbaBase64(),
    });

    const body = parseToolText(await tools.renderGui('game.StarterGui.MainMenu'));

    expect(body).toMatchObject({ success: false });
    expect(body.error).toContain('PNG conversion failed');
    expect(body.error).toContain('Buffer size mismatch');
  });

  test('renderGui forwards instancePath and size caps, passing through non-image responses', async () => {
    const bridge = {
      sendRequest: jest.fn().mockResolvedValue({ success: false, error: 'not available' }),
    } as unknown as BridgeService;
    const tools = new RobloxStudioTools(bridge);

    const body = parseToolText(
      await tools.renderGui('game.StarterGui.HUD', { maxWidth: 512, maxHeight: 256 })
    );

    expect(body).toEqual({ success: false, error: 'not available' });
    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/render-gui', {
      instancePath: 'game.StarterGui.HUD',
      region: 'element',
      maxWidth: 512,
      maxHeight: 256,
    });
  });

  test('renderGui forwards an explicit screen region', async () => {
    const bridge = {
      sendRequest: jest.fn().mockResolvedValue({ success: false, error: 'not available' }),
    } as unknown as BridgeService;
    const tools = new RobloxStudioTools(bridge);

    await tools.renderGui('game.StarterGui.MainMenu', { region: 'screen' });

    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/render-gui', {
      instancePath: 'game.StarterGui.MainMenu',
      region: 'screen',
      maxWidth: undefined,
      maxHeight: undefined,
    });
  });

  test('captureScreenshot returns a structured conversion error for bad buffers', async () => {
    const tools = setup({
      success: true,
      width: 2,
      height: 2,
      base64: onePixelRgbaBase64(),
    });

    const body = parseToolText(await tools.captureScreenshot(2, 2));

    expect(body.success).toBe(false);
    expect(body.error).toContain('PNG conversion failed');
    expect(body.error).toContain('Buffer size mismatch');
    expect(body.originalResponse.width).toBe(2);
  });

  test('renderObjectView returns a structured conversion error for bad buffers', async () => {
    const tools = setup({
      success: true,
      width: 2,
      height: 2,
      base64: onePixelRgbaBase64(),
    });

    const body = parseToolText(await tools.renderObjectView('game.Workspace.Part'));

    expect(body).toMatchObject({ success: false });
    expect(body.error).toContain('PNG conversion failed');
    expect(body.error).toContain('Buffer size mismatch');
  });
});
