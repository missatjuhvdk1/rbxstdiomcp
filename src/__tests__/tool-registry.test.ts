import { allTools, toolsByName } from '../tools/registry';
import { createMockTools } from './helpers';

type HandlerCase = {
  name: string;
  args: Record<string, unknown>;
  method: string;
  expectedArgs: unknown[];
};

const handlerCases: HandlerCase[] = [
  { name: 'get_place_info', args: {}, method: 'getPlaceInfo', expectedArgs: [] },
  {
    name: 'get_services',
    args: { serviceName: 'Workspace' },
    method: 'getServices',
    expectedArgs: ['Workspace'],
  },
  {
    name: 'get_instance_properties',
    args: { instancePath: 'game.Workspace.Part' },
    method: 'getInstanceProperties',
    expectedArgs: ['game.Workspace.Part'],
  },
  {
    name: 'get_class_info',
    args: { className: 'Part' },
    method: 'getClassInfo',
    expectedArgs: ['Part'],
  },
  {
    name: 'get_project_structure',
    args: { path: 'game', maxDepth: 5, scriptsOnly: true },
    method: 'getProjectStructure',
    expectedArgs: ['game', 5, true],
  },
  { name: 'get_selection', args: {}, method: 'getSelection', expectedArgs: [] },
  {
    name: 'grep',
    args: {
      pattern: 'require',
      path: 'game.ServerScriptService',
      glob: 'Main.*',
      type: ['Script'],
      '-i': true,
      '-A': 1,
      '-B': 2,
      '-C': 3,
      output_mode: 'content',
      head_limit: 4,
      multiline: true,
    },
    method: 'grep',
    expectedArgs: [
      'require',
      {
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
    ],
  },
  {
    name: 'get_output',
    args: {
      limit: 25,
      since: 123,
      messageTypes: ['MessageWarning'],
      clear: true,
    },
    method: 'getOutput',
    expectedArgs: [25, 123, ['MessageWarning'], true],
  },
  {
    name: 'set_property',
    args: { instancePath: 'game.Workspace.Part', propertyName: 'Name', propertyValue: 'Renamed' },
    method: 'setProperty',
    expectedArgs: ['game.Workspace.Part', 'Name', 'Renamed'],
  },
  {
    name: 'mass_set_property',
    args: { paths: ['a', 'b'], propertyName: 'Anchored', propertyValue: true },
    method: 'massSetProperty',
    expectedArgs: [['a', 'b'], 'Anchored', true],
  },
  {
    name: 'mass_get_property',
    args: { paths: ['a', 'b'], propertyName: 'Name' },
    method: 'massGetProperty',
    expectedArgs: [['a', 'b'], 'Name'],
  },
  {
    name: 'get_attribute',
    args: { instancePath: 'game.Workspace.Part', attributeName: 'Health' },
    method: 'getAttribute',
    expectedArgs: ['game.Workspace.Part', 'Health'],
  },
  {
    name: 'set_attribute',
    args: {
      instancePath: 'game.Workspace.Part',
      attributeName: 'Health',
      attributeValue: 100,
      valueType: 'number',
    },
    method: 'setAttribute',
    expectedArgs: ['game.Workspace.Part', 'Health', 100, 'number'],
  },
  {
    name: 'get_attributes',
    args: { instancePath: 'game.Workspace.Part' },
    method: 'getAttributes',
    expectedArgs: ['game.Workspace.Part'],
  },
  {
    name: 'delete_attribute',
    args: { instancePath: 'game.Workspace.Part', attributeName: 'Health' },
    method: 'deleteAttribute',
    expectedArgs: ['game.Workspace.Part', 'Health'],
  },
  {
    name: 'get_tags',
    args: { instancePath: 'game.Workspace.Part' },
    method: 'getTags',
    expectedArgs: ['game.Workspace.Part'],
  },
  {
    name: 'add_tag',
    args: { instancePath: 'game.Workspace.Part', tagName: 'Enemy' },
    method: 'addTag',
    expectedArgs: ['game.Workspace.Part', 'Enemy'],
  },
  {
    name: 'remove_tag',
    args: { instancePath: 'game.Workspace.Part', tagName: 'Enemy' },
    method: 'removeTag',
    expectedArgs: ['game.Workspace.Part', 'Enemy'],
  },
  { name: 'get_tagged', args: { tagName: 'Enemy' }, method: 'getTagged', expectedArgs: ['Enemy'] },
  {
    name: 'create_object',
    args: { className: 'Part', parent: 'game.Workspace', name: 'Block' },
    method: 'createObject',
    expectedArgs: ['Part', 'game.Workspace', 'Block'],
  },
  {
    name: 'delete_object',
    args: { instancePath: 'game.Workspace.Block' },
    method: 'deleteObject',
    expectedArgs: ['game.Workspace.Block'],
  },
  {
    name: 'clone_instance',
    args: {
      sourcePath: 'game.Workspace.Block',
      targetParent: 'game.Workspace',
      newName: 'Block2',
    },
    method: 'cloneInstance',
    expectedArgs: ['game.Workspace.Block', 'game.Workspace', 'Block2'],
  },
  {
    name: 'move_instance',
    args: { instancePath: 'game.Workspace.Block', newParent: 'game.ReplicatedStorage' },
    method: 'moveInstance',
    expectedArgs: ['game.Workspace.Block', 'game.ReplicatedStorage'],
  },
  {
    name: 'insert_asset',
    args: { assetId: 123, folderName: 'Assets', targetParent: 'game.Workspace' },
    method: 'insertAsset',
    expectedArgs: [123, 'Assets', 'game.Workspace'],
  },
  {
    name: 'get_script_source',
    args: { instancePath: 'game.ServerScriptService.Main', startLine: 2, endLine: 4 },
    method: 'getScriptSource',
    expectedArgs: ['game.ServerScriptService.Main', 2, 4],
  },
  {
    name: 'set_script_source',
    args: { instancePath: 'game.ServerScriptService.Main', source: 'print("hi")' },
    method: 'setScriptSource',
    expectedArgs: ['game.ServerScriptService.Main', 'print("hi")'],
  },
  {
    name: 'edit_script',
    args: {
      instancePath: 'game.ServerScriptService.Main',
      old_string: 'old',
      new_string: 'new',
      replace_all: true,
      validate_after: false,
    },
    method: 'editScript',
    expectedArgs: ['game.ServerScriptService.Main', 'old', 'new', true, false],
  },
  {
    name: 'get_script_function',
    args: { instancePath: 'game.ServerScriptService.Main', function_name: 'init' },
    method: 'getScriptFunction',
    expectedArgs: ['game.ServerScriptService.Main', 'init'],
  },
  {
    name: 'find_and_replace_in_scripts',
    args: {
      paths: ['game.ServerScriptService.Main'],
      old_string: 'old',
      new_string: 'new',
      validate_after: false,
    },
    method: 'findAndReplaceInScripts',
    expectedArgs: [['game.ServerScriptService.Main'], 'old', 'new', false],
  },
  {
    name: 'validate_script',
    args: { source: 'print("ok")' },
    method: 'validateScript',
    expectedArgs: [undefined, 'print("ok")'],
  },
  { name: 'undo', args: { count: 3 }, method: 'undo', expectedArgs: [3] },
  { name: 'redo', args: { count: 2 }, method: 'redo', expectedArgs: [2] },
  {
    name: 'get_history',
    args: { limit: 7, include_details: true },
    method: 'getHistory',
    expectedArgs: [7, true],
  },
  { name: 'play_solo', args: {}, method: 'playSolo', expectedArgs: [] },
  { name: 'stop_play', args: {}, method: 'stopPlay', expectedArgs: [] },
  {
    name: 'get_playtest_output',
    args: { sinceSeq: 10, limit: 50, messageTypes: ['MessageOutput'] },
    method: 'getPlaytestOutput',
    expectedArgs: [10, 50, ['MessageOutput']],
  },
  {
    name: 'run_live_lua',
    args: {
      code: 'return 1',
      target: 'client',
      playerName: 'Player1',
      timeoutMs: 2000,
      captureLogs: false,
    },
    method: 'runLiveLua',
    expectedArgs: ['return 1', 'client', 'Player1', 2000, false],
  },
  {
    name: 'capture_screenshot',
    args: { maxWidth: 320, maxHeight: 240 },
    method: 'captureScreenshot',
    expectedArgs: [320, 240],
  },
  {
    name: 'render_object_view',
    args: {
      instancePath: 'game.Workspace.Block',
      angle: 'front',
      resolution: { width: 256, height: 256 },
      lighting: 'studio',
      background: 'grid',
      autoDistance: false,
    },
    method: 'renderObjectView',
    expectedArgs: [
      'game.Workspace.Block',
      {
        angle: 'front',
        resolution: { width: 256, height: 256 },
        lighting: 'studio',
        background: 'grid',
        autoDistance: false,
      },
    ],
  },
  {
    name: 'render_gui',
    args: {
      instancePath: 'game.StarterGui.MainMenu',
      region: 'screen',
      maxWidth: 512,
      maxHeight: 256,
    },
    method: 'renderGui',
    expectedArgs: [
      'game.StarterGui.MainMenu',
      { region: 'screen', maxWidth: 512, maxHeight: 256 },
    ],
  },
  {
    name: 'focus_camera',
    args: {
      instancePath: 'game.Workspace.Block',
      angle: { pitch: 10, yaw: 20 },
      distance: 30,
      autoDistance: false,
    },
    method: 'focusCamera',
    expectedArgs: [
      'game.Workspace.Block',
      { angle: { pitch: 10, yaw: 20 }, distance: 30, autoDistance: false },
    ],
  },
  { name: 'execute_lua', args: { code: 'print("hi")' }, method: 'executeLua', expectedArgs: ['print("hi")'] },
  {
    name: 'search_roblox_docs',
    args: { query: 'Motor6D C0', max_hits: 5, scope: 'en-us/reference' },
    method: 'searchRobloxDocs',
    expectedArgs: [
      'Motor6D C0',
      {
        scope: 'en-us/reference',
        extensions: undefined,
        useRegex: false,
        caseSensitive: false,
        contextLines: 0,
        windowLines: 3,
        maxHits: 5,
        semantic: true,
      },
    ],
  },
  {
    name: 'get_roblox_doc',
    args: { path: 'en-us/reference/engine/classes/Part.yaml' },
    method: 'getRobloxDoc',
    expectedArgs: ['en-us/reference/engine/classes/Part.yaml'],
  },
  {
    name: 'list_roblox_docs',
    args: { path: 'en-us/reference', limit: 20, offset: 5 },
    method: 'listRobloxDocs',
    expectedArgs: ['en-us/reference', { limit: 20, offset: 5 }],
  },
  {
    name: 'get_roblox_api_reference',
    args: { name: 'Part', category: 'class' },
    method: 'getRobloxApiReference',
    expectedArgs: ['Part', 'class'],
  },
];

describe('MCP tool registry', () => {
  test('has a stable one-to-one lookup for every tool', () => {
    expect(allTools.length).toBeGreaterThan(30);
    expect(Object.keys(toolsByName).sort()).toEqual(allTools.map((tool) => tool.name).sort());
    expect(handlerCases.map((testCase) => testCase.name).sort()).toEqual(
      allTools.map((tool) => tool.name).sort(),
    );
  });

  test('every exposed tool has MCP-visible metadata', () => {
    for (const tool of allTools) {
      expect(tool.name).toMatch(/^[a-z][a-z0-9_]*$/);
      expect(tool.description.length).toBeGreaterThan(10);
      expect(tool.inputSchema).toMatchObject({ type: 'object' });
      expect(typeof tool.handler).toBe('function');
    }
  });

  test.each(handlerCases)('$name dispatches to $method with normalized arguments', async (testCase) => {
    const { tools, methods } = createMockTools();
    const tool = toolsByName[testCase.name];

    const result = await tool.handler(testCase.args, { tools });

    expect(result).toBe(`${testCase.method}:result`);
    expect(methods.get(testCase.method)).toHaveBeenCalledTimes(1);
    expect(methods.get(testCase.method)).toHaveBeenCalledWith(...testCase.expectedArgs);
  });
});
