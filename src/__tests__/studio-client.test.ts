import { BridgeService } from '../bridge-service';
import { StudioHttpClient } from '../tools/studio-client';

describe('StudioHttpClient', () => {
  test('returns bridge responses unchanged', async () => {
    const bridge = {
      sendRequest: jest.fn().mockResolvedValue({ ok: true }),
    } as unknown as BridgeService;

    await expect(new StudioHttpClient(bridge).request('/api/test', { a: 1 })).resolves.toEqual({
      ok: true,
    });
    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/test', { a: 1 });
  });

  test('maps bridge request timeouts to actionable Studio plugin guidance', async () => {
    const bridge = {
      sendRequest: jest.fn().mockRejectedValue(new Error('Request timeout')),
    } as unknown as BridgeService;

    await expect(new StudioHttpClient(bridge).request('/api/test', {})).rejects.toThrow(
      'Studio plugin connection timeout',
    );
  });

  test('preserves non-timeout bridge errors', async () => {
    const bridge = {
      sendRequest: jest.fn().mockRejectedValue(new Error('boom')),
    } as unknown as BridgeService;

    await expect(new StudioHttpClient(bridge).request('/api/test', {})).rejects.toThrow('boom');
  });
});
