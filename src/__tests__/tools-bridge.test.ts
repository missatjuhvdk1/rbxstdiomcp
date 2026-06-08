import { BridgeService } from '../bridge-service';
import { RobloxStudioTools } from '../tools/index';
import { parseToolText } from './helpers';

type MockBridge = BridgeService & {
  sendRequest: jest.Mock<Promise<any>, [string, any]>;
};

function setup(response: any = { success: true, value: 'studio-response' }) {
  const bridge = {
    sendRequest: jest.fn().mockResolvedValue(response),
  } as MockBridge;
  const tools = new RobloxStudioTools(bridge);
  return { bridge, tools };
}

type ForwardCase = {
  name: string;
  call: (tools: RobloxStudioTools) => Promise<any>;
  endpoint: string;
  payload: Record<string, unknown>;
};

const forwardCases: ForwardCase[] = [
  {
    name: 'getFileTree',
    call: (tools) => tools.getFileTree('game.Workspace'),
    endpoint: '/api/file-tree',
    payload: { path: 'game.Workspace' },
  },
  {
    name: 'searchFiles',
    call: (tools) => tools.searchFiles('Enemy', 'source'),
    endpoint: '/api/search-files',
    payload: { query: 'Enemy', searchType: 'source' },
  },
  {
    name: 'getPlaceInfo',
    call: (tools) => tools.getPlaceInfo(),
    endpoint: '/api/place-info',
    payload: {},
  },
  {
    name: 'getServices',
    call: (tools) => tools.getServices('Workspace'),
    endpoint: '/api/services',
    payload: { serviceName: 'Workspace' },
  },
  {
    name: 'searchObjects',
    call: (tools) => tools.searchObjects('Part', 'className', 'Name'),
    endpoint: '/api/search-objects',
    payload: { query: 'Part', searchType: 'className', propertyName: 'Name' },
  },
  {
    name: 'getInstanceProperties',
    call: (tools) => tools.getInstanceProperties('game.Workspace.Part'),
    endpoint: '/api/instance-properties',
    payload: { instancePath: 'game.Workspace.Part' },
  },
  {
    name: 'getInstanceChildren',
    call: (tools) => tools.getInstanceChildren('game.Workspace'),
    endpoint: '/api/instance-children',
    payload: { instancePath: 'game.Workspace' },
  },
  {
    name: 'searchByProperty',
    call: (tools) => tools.searchByProperty('Name', 'Part'),
    endpoint: '/api/search-by-property',
    payload: { propertyName: 'Name', propertyValue: 'Part' },
  },
  {
    name: 'getClassInfo',
    call: (tools) => tools.getClassInfo('Part'),
    endpoint: '/api/class-info',
    payload: { className: 'Part' },
  },
  {
    name: 'getProjectStructure',
    call: (tools) => tools.getProjectStructure('game', 5, true),
    endpoint: '/api/project-structure',
    payload: { path: 'game', maxDepth: 5, scriptsOnly: true },
  },
  {
    name: 'grep',
    call: (tools) =>
      tools.grep('require', {
        path: 'game.ServerScriptService',
        glob: 'Main.*',
        type: ['Script'],
        caseInsensitive: true,
        after: 1,
        before: 2,
        context: 3,
        outputMode: 'content',
        headLimit: 4,
        multiline: true,
      }),
    endpoint: '/api/grep',
    payload: {
      pattern: 'require',
      path: 'game.ServerScriptService',
      glob: 'Main.*',
      type: ['Script'],
      caseInsensitive: true,
      after: 1,
      before: 2,
      context: 3,
      outputMode: 'content',
      headLimit: 4,
      multiline: true,
    },
  },
  {
    name: 'setProperty',
    call: (tools) => tools.setProperty('game.Workspace.Part', 'Anchored', true),
    endpoint: '/api/set-property',
    payload: { instancePath: 'game.Workspace.Part', propertyName: 'Anchored', propertyValue: true },
  },
  {
    name: 'massSetProperty',
    call: (tools) => tools.massSetProperty(['a', 'b'], 'Transparency', 0.5),
    endpoint: '/api/mass-set-property',
    payload: { paths: ['a', 'b'], propertyName: 'Transparency', propertyValue: 0.5 },
  },
  {
    name: 'massGetProperty',
    call: (tools) => tools.massGetProperty(['a', 'b'], 'Name'),
    endpoint: '/api/mass-get-property',
    payload: { paths: ['a', 'b'], propertyName: 'Name' },
  },
  {
    name: 'createObject',
    call: (tools) => tools.createObject('Part', 'game.Workspace', 'Block'),
    endpoint: '/api/create-object',
    payload: { className: 'Part', parent: 'game.Workspace', name: 'Block' },
  },
  {
    name: 'createObjectWithProperties',
    call: (tools) =>
      tools.createObjectWithProperties('Part', 'game.Workspace', 'Block', { Anchored: true }),
    endpoint: '/api/create-object',
    payload: {
      className: 'Part',
      parent: 'game.Workspace',
      name: 'Block',
      properties: { Anchored: true },
    },
  },
  {
    name: 'massCreateObjects',
    call: (tools) => tools.massCreateObjects([{ className: 'Part', parent: 'game.Workspace' }]),
    endpoint: '/api/mass-create-objects',
    payload: { objects: [{ className: 'Part', parent: 'game.Workspace' }] },
  },
  {
    name: 'massCreateObjectsWithProperties',
    call: (tools) =>
      tools.massCreateObjectsWithProperties([
        { className: 'Part', parent: 'game.Workspace', properties: { Anchored: true } },
      ]),
    endpoint: '/api/mass-create-objects-with-properties',
    payload: {
      objects: [{ className: 'Part', parent: 'game.Workspace', properties: { Anchored: true } }],
    },
  },
  {
    name: 'deleteObject',
    call: (tools) => tools.deleteObject('game.Workspace.Block'),
    endpoint: '/api/delete-object',
    payload: { instancePath: 'game.Workspace.Block' },
  },
  {
    name: 'smartDuplicate',
    call: (tools) => tools.smartDuplicate('game.Workspace.Block', 3, { namePattern: 'Block{n}' }),
    endpoint: '/api/smart-duplicate',
    payload: { instancePath: 'game.Workspace.Block', count: 3, options: { namePattern: 'Block{n}' } },
  },
  {
    name: 'massDuplicate',
    call: (tools) =>
      tools.massDuplicate([{ instancePath: 'game.Workspace.Block', count: 2 }]),
    endpoint: '/api/mass-duplicate',
    payload: { duplications: [{ instancePath: 'game.Workspace.Block', count: 2 }] },
  },
  {
    name: 'setCalculatedProperty',
    call: (tools) => tools.setCalculatedProperty(['a'], 'Size', 'x * 2', { x: 3 }),
    endpoint: '/api/set-calculated-property',
    payload: { paths: ['a'], propertyName: 'Size', formula: 'x * 2', variables: { x: 3 } },
  },
  {
    name: 'setRelativeProperty',
    call: (tools) => tools.setRelativeProperty(['a'], 'Position', 'add', 5, 'X'),
    endpoint: '/api/set-relative-property',
    payload: { paths: ['a'], propertyName: 'Position', operation: 'add', value: 5, component: 'X' },
  },
  {
    name: 'getScriptSource',
    call: (tools) => tools.getScriptSource('game.ServerScriptService.Main', 2, 4),
    endpoint: '/api/get-script-source',
    payload: { instancePath: 'game.ServerScriptService.Main', startLine: 2, endLine: 4 },
  },
  {
    name: 'setScriptSource',
    call: (tools) => tools.setScriptSource('game.ServerScriptService.Main', 'print("hi")'),
    endpoint: '/api/set-script-source',
    payload: { instancePath: 'game.ServerScriptService.Main', source: 'print("hi")' },
  },
  {
    name: 'editScript',
    call: (tools) => tools.editScript('game.ServerScriptService.Main', 'old', 'new', true, false),
    endpoint: '/api/edit-script',
    payload: {
      instancePath: 'game.ServerScriptService.Main',
      oldString: 'old',
      newString: 'new',
      replaceAll: true,
      validateAfter: false,
    },
  },
  {
    name: 'searchScript',
    call: (tools) => tools.searchScript('game.ServerScriptService.Main', 'foo', true, 2),
    endpoint: '/api/search-script',
    payload: {
      instancePath: 'game.ServerScriptService.Main',
      pattern: 'foo',
      useRegex: true,
      contextLines: 2,
    },
  },
  {
    name: 'getScriptFunction',
    call: (tools) => tools.getScriptFunction('game.ServerScriptService.Main', 'init'),
    endpoint: '/api/get-script-function',
    payload: { instancePath: 'game.ServerScriptService.Main', functionName: 'init' },
  },
  {
    name: 'findAndReplaceInScripts',
    call: (tools) => tools.findAndReplaceInScripts(['a', 'b'], 'old', 'new', false),
    endpoint: '/api/find-and-replace-in-scripts',
    payload: { paths: ['a', 'b'], oldString: 'old', newString: 'new', validateAfter: false },
  },
  {
    name: 'getAttribute',
    call: (tools) => tools.getAttribute('game.Workspace.Part', 'Health'),
    endpoint: '/api/get-attribute',
    payload: { instancePath: 'game.Workspace.Part', attributeName: 'Health' },
  },
  {
    name: 'setAttribute',
    call: (tools) => tools.setAttribute('game.Workspace.Part', 'Health', 100, 'number'),
    endpoint: '/api/set-attribute',
    payload: {
      instancePath: 'game.Workspace.Part',
      attributeName: 'Health',
      attributeValue: 100,
      valueType: 'number',
    },
  },
  {
    name: 'getAttributes',
    call: (tools) => tools.getAttributes('game.Workspace.Part'),
    endpoint: '/api/get-attributes',
    payload: { instancePath: 'game.Workspace.Part' },
  },
  {
    name: 'deleteAttribute',
    call: (tools) => tools.deleteAttribute('game.Workspace.Part', 'Health'),
    endpoint: '/api/delete-attribute',
    payload: { instancePath: 'game.Workspace.Part', attributeName: 'Health' },
  },
  {
    name: 'getTags',
    call: (tools) => tools.getTags('game.Workspace.Part'),
    endpoint: '/api/get-tags',
    payload: { instancePath: 'game.Workspace.Part' },
  },
  {
    name: 'addTag',
    call: (tools) => tools.addTag('game.Workspace.Part', 'Enemy'),
    endpoint: '/api/add-tag',
    payload: { instancePath: 'game.Workspace.Part', tagName: 'Enemy' },
  },
  {
    name: 'removeTag',
    call: (tools) => tools.removeTag('game.Workspace.Part', 'Enemy'),
    endpoint: '/api/remove-tag',
    payload: { instancePath: 'game.Workspace.Part', tagName: 'Enemy' },
  },
  {
    name: 'getTagged',
    call: (tools) => tools.getTagged('Enemy'),
    endpoint: '/api/get-tagged',
    payload: { tagName: 'Enemy' },
  },
  {
    name: 'getSelection',
    call: (tools) => tools.getSelection(),
    endpoint: '/api/get-selection',
    payload: {},
  },
  {
    name: 'getOutput',
    call: (tools) => tools.getOutput(10, 123, ['MessageWarning'], true),
    endpoint: '/api/get-output',
    payload: { limit: 10, since: 123, messageTypes: ['MessageWarning'], clear: true },
  },
  {
    name: 'cloneInstance',
    call: (tools) => tools.cloneInstance('game.Workspace.Block', 'game.Workspace', 'Copy'),
    endpoint: '/api/clone-instance',
    payload: { sourcePath: 'game.Workspace.Block', targetParent: 'game.Workspace', newName: 'Copy' },
  },
  {
    name: 'moveInstance',
    call: (tools) => tools.moveInstance('game.Workspace.Block', 'game.ReplicatedStorage'),
    endpoint: '/api/move-instance',
    payload: { instancePath: 'game.Workspace.Block', newParent: 'game.ReplicatedStorage' },
  },
  {
    name: 'validateScript',
    call: (tools) => tools.validateScript(undefined, 'print("ok")'),
    endpoint: '/api/validate-script',
    payload: { instancePath: undefined, source: 'print("ok")' },
  },
  {
    name: 'insertAsset',
    call: (tools) => tools.insertAsset(123, 'Assets', 'game.Workspace'),
    endpoint: '/api/insert-asset',
    payload: { assetId: 123, folderName: 'Assets', targetParent: 'game.Workspace' },
  },
  {
    name: 'focusCamera',
    call: (tools) =>
      tools.focusCamera('game.Workspace.Block', { angle: 'front', distance: 20, autoDistance: false }),
    endpoint: '/api/focus-camera',
    payload: {
      instancePath: 'game.Workspace.Block',
      angle: 'front',
      distance: 20,
      autoDistance: false,
    },
  },
  {
    name: 'executeLua',
    call: (tools) => tools.executeLua('print("hi")'),
    endpoint: '/api/execute-lua',
    payload: { code: 'print("hi")' },
  },
];

describe('RobloxStudioTools bridge forwarding', () => {
  test.each(forwardCases)('$name forwards exact endpoint and payload', async (testCase) => {
    const { bridge, tools } = setup();

    const result = await testCase.call(tools);

    expect(bridge.sendRequest).toHaveBeenCalledWith(testCase.endpoint, testCase.payload);
    expect(parseToolText(result)).toEqual({ success: true, value: 'studio-response' });
  });

  test('grep fills Studio-side defaults', async () => {
    const { bridge, tools } = setup();

    await tools.grep('Enemy');

    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/grep', {
      pattern: 'Enemy',
      path: 'game',
      glob: undefined,
      type: ['LuaSourceContainer'],
      caseInsensitive: false,
      after: 0,
      before: 0,
      context: 0,
      outputMode: 'files_with_matches',
      headLimit: 0,
      multiline: false,
    });
  });

  test('undo, redo, and history clamp counts before crossing the bridge', async () => {
    const { bridge, tools } = setup();

    await tools.undo(250.9);
    await tools.redo(0);
    await tools.getHistory(-5, true);

    expect(bridge.sendRequest).toHaveBeenNthCalledWith(1, '/api/undo', { count: 100 });
    expect(bridge.sendRequest).toHaveBeenNthCalledWith(2, '/api/redo', { count: 1 });
    expect(bridge.sendRequest).toHaveBeenNthCalledWith(3, '/api/get-history', {
      limit: 1,
      includeDetails: true,
    });
  });

  test('captureScreenshot and renderObjectView forward defaults for non-image responses', async () => {
    const { bridge, tools } = setup({ success: false, error: 'not available' });

    expect(parseToolText(await tools.captureScreenshot())).toEqual({
      success: false,
      error: 'not available',
    });
    expect(parseToolText(await tools.renderObjectView('game.Workspace.Block'))).toEqual({
      success: false,
      error: 'not available',
    });

    expect(bridge.sendRequest).toHaveBeenNthCalledWith(1, '/api/capture-screenshot', {
      maxWidth: 768,
      maxHeight: 768,
      returnBase64: true,
    });
    expect(bridge.sendRequest).toHaveBeenNthCalledWith(2, '/api/render-object-view', {
      instancePath: 'game.Workspace.Block',
      angle: 'iso',
      resolution: { width: 768, height: 768 },
      lighting: 'bright',
      background: 'transparent',
      autoDistance: true,
    });
  });
});
