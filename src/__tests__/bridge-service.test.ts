import { BridgeService } from '../bridge-service';
import { observeRejection } from './helpers';

describe('BridgeService', () => {
  let bridgeService: BridgeService;

  beforeEach(() => {
    bridgeService = new BridgeService();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('Request Management', () => {
    test('should create and store a pending request', async () => {
      const endpoint = '/api/test';
      const data = { test: 'data' };
      
      bridgeService.sendRequest(endpoint, data);
      
      // Check that request is pending
      const pendingRequest = bridgeService.getPendingRequest();
      expect(pendingRequest).toBeTruthy();
      expect(pendingRequest?.request.endpoint).toBe(endpoint);
      expect(pendingRequest?.request.data).toEqual(data);
    });

    test('should resolve request when response is received', async () => {
      const endpoint = '/api/test';
      const data = { test: 'data' };
      const response = { result: 'success' };
      
      const requestPromise = bridgeService.sendRequest(endpoint, data);
      const pendingRequest = bridgeService.getPendingRequest();
      
      // Resolve the request
      bridgeService.resolveRequest(pendingRequest!.requestId, response);
      
      const result = await requestPromise;
      expect(result).toEqual(response);
    });

    test('should reject request on error', async () => {
      const endpoint = '/api/test';
      const data = { test: 'data' };
      const error = 'Test error';
      
      const requestPromise = bridgeService.sendRequest(endpoint, data);
      const pendingRequest = bridgeService.getPendingRequest();
      
      // Reject the request
      bridgeService.rejectRequest(pendingRequest!.requestId, error);
      
      await expect(requestPromise).rejects.toEqual(error);
    });

    test('should timeout request after 30 seconds', async () => {
      const endpoint = '/api/test';
      const data = { test: 'data' };
      
      const requestPromise = bridgeService.sendRequest(endpoint, data);
      const rejection = observeRejection(requestPromise);
      
      // Fast-forward time by 31 seconds
      jest.advanceTimersByTime(31000);
      
      await expect(rejection).resolves.toThrow('Request timeout');
    });
  });

  describe('Cleanup Operations', () => {
    test('should clean up old requests', async () => {
      // Create multiple requests
      const promises = [
        bridgeService.sendRequest('/api/test1', {}),
        bridgeService.sendRequest('/api/test2', {}),
        bridgeService.sendRequest('/api/test3', {})
      ];
      const rejections = promises.map(observeRejection);
      
      // Fast-forward time by 31 seconds
      jest.advanceTimersByTime(31000);
      
      // Clean up old requests
      bridgeService.cleanupOldRequests();
      
      // All requests should be rejected
      for (const rejection of rejections) {
        await expect(rejection).resolves.toThrow('Request timeout');
      }
      
      // No pending requests should remain
      expect(bridgeService.getPendingRequest()).toBeNull();
    });

    test('should clear all pending requests on disconnect', async () => {
      // Create multiple requests
      const promises = [
        bridgeService.sendRequest('/api/test1', {}),
        bridgeService.sendRequest('/api/test2', {}),
        bridgeService.sendRequest('/api/test3', {})
      ];
      const rejections = promises.map(observeRejection);
      
      // Clear all requests
      bridgeService.clearAllPendingRequests();
      
      // All requests should be rejected with connection closed error
      for (const rejection of rejections) {
        await expect(rejection).resolves.toThrow('Connection closed');
      }
      
      // No pending requests should remain
      expect(bridgeService.getPendingRequest()).toBeNull();
    });
  });

  describe('Request Priority', () => {
    test('should return the oldest pending request without consuming it', async () => {
      // Create requests with small delays
      jest.setSystemTime(1000);
      const first = bridgeService.sendRequest('/api/test1', { order: 1 });
      jest.setSystemTime(1010);
      const second = bridgeService.sendRequest('/api/test2', { order: 2 });
      jest.setSystemTime(1020);
      const third = bridgeService.sendRequest('/api/test3', { order: 3 });
      
      // Should get the first (oldest) request
      const firstRequest = bridgeService.getPendingRequest();
      expect(firstRequest?.request.data.order).toBe(1);

      // Polling peeks; the same request remains pending until resolved.
      expect(bridgeService.getPendingRequest()?.request.data.order).toBe(1);
      bridgeService.resolveRequest(firstRequest!.requestId, { ok: 1 });
      
      // Should get the second request next
      const secondRequest = bridgeService.getPendingRequest();
      expect(secondRequest?.request.data.order).toBe(2);
      bridgeService.resolveRequest(secondRequest!.requestId, { ok: 2 });
      
      // Should get the third request last
      const thirdRequest = bridgeService.getPendingRequest();
      expect(thirdRequest?.request.data.order).toBe(3);
      bridgeService.resolveRequest(thirdRequest!.requestId, { ok: 3 });

      await expect(first).resolves.toEqual({ ok: 1 });
      await expect(second).resolves.toEqual({ ok: 2 });
      await expect(third).resolves.toEqual({ ok: 3 });
    });
  });
});
