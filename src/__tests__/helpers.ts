import type { RobloxStudioTools } from '../tools/index.js';

export function parseToolText(result: any): any {
  expect(result).toHaveProperty('content');
  expect(result.content[0]).toMatchObject({ type: 'text' });
  return JSON.parse(result.content[0].text);
}

export function createMockTools(): {
  tools: RobloxStudioTools;
  methods: Map<string, jest.Mock>;
} {
  const methods = new Map<string, jest.Mock>();
  const tools = new Proxy(
    {},
    {
      get(_target, prop: string) {
        if (!methods.has(prop)) {
          methods.set(prop, jest.fn().mockResolvedValue(`${prop}:result`));
        }
        return methods.get(prop);
      },
    },
  ) as RobloxStudioTools;

  return { tools, methods };
}

export function observeRejection<T>(promise: Promise<T>): Promise<unknown> {
  return promise.then(
    () => {
      throw new Error('Expected promise to reject');
    },
    (error) => error,
  );
}
