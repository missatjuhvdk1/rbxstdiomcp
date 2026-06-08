import { BridgeService } from '../bridge-service';
import { RobloxStudioTools } from '../tools/index';
import { parseToolText } from './helpers';

function setup(response: any = { success: true }) {
  const bridge = {
    sendRequest: jest.fn().mockResolvedValue(response),
  } as unknown as BridgeService & { sendRequest: jest.Mock };
  const tools = new RobloxStudioTools(bridge);
  return { bridge, tools };
}

describe('RobloxStudioTools argument validation', () => {
  test.each([
    ['getInstanceProperties', (tools: RobloxStudioTools) => tools.getInstanceProperties(''), /Instance path is required/],
    ['getInstanceChildren', (tools: RobloxStudioTools) => tools.getInstanceChildren(''), /Instance path is required/],
    ['searchByProperty', (tools: RobloxStudioTools) => tools.searchByProperty('', 'value'), /Property name and value/],
    ['getClassInfo', (tools: RobloxStudioTools) => tools.getClassInfo(''), /Class name is required/],
    ['grep', (tools: RobloxStudioTools) => tools.grep(''), /pattern is required/],
    ['setProperty', (tools: RobloxStudioTools) => tools.setProperty('', 'Name', 'x'), /Instance path and property name/],
    ['massSetProperty', (tools: RobloxStudioTools) => tools.massSetProperty([], 'Name', 'x'), /Paths array/],
    ['massGetProperty', (tools: RobloxStudioTools) => tools.massGetProperty([], 'Name'), /Paths array/],
    ['createObject', (tools: RobloxStudioTools) => tools.createObject('', 'game'), /Class name and parent/],
    ['createObjectWithProperties', (tools: RobloxStudioTools) => tools.createObjectWithProperties('', 'game'), /Class name and parent/],
    ['massCreateObjects', (tools: RobloxStudioTools) => tools.massCreateObjects([]), /Objects array/],
    [
      'massCreateObjectsWithProperties',
      (tools: RobloxStudioTools) => tools.massCreateObjectsWithProperties([]),
      /Objects array/,
    ],
    ['deleteObject', (tools: RobloxStudioTools) => tools.deleteObject(''), /Instance path is required/],
    ['smartDuplicate', (tools: RobloxStudioTools) => tools.smartDuplicate('game.Workspace.Part', 0), /count > 0/],
    ['massDuplicate', (tools: RobloxStudioTools) => tools.massDuplicate([]), /Duplications array/],
    [
      'setCalculatedProperty',
      (tools: RobloxStudioTools) => tools.setCalculatedProperty([], 'Name', 'formula'),
      /Paths, property name, and formula/,
    ],
    [
      'setRelativeProperty',
      (tools: RobloxStudioTools) => tools.setRelativeProperty([], 'Name', 'add', 1),
      /Paths, property name, operation, and value/,
    ],
    ['getScriptSource', (tools: RobloxStudioTools) => tools.getScriptSource(''), /Instance path is required/],
    [
      'setScriptSource',
      (tools: RobloxStudioTools) => tools.setScriptSource('game.Script', undefined as any),
      /source code string/,
    ],
    ['editScript missing path', (tools: RobloxStudioTools) => tools.editScript('', 'a', 'b'), /Instance path/],
    ['editScript missing old', (tools: RobloxStudioTools) => tools.editScript('game.Script', undefined as any, 'b'), /old_string/],
    ['editScript missing new', (tools: RobloxStudioTools) => tools.editScript('game.Script', 'a', undefined as any), /new_string/],
    ['editScript identical', (tools: RobloxStudioTools) => tools.editScript('game.Script', 'a', 'a'), /must be different/],
    ['searchScript', (tools: RobloxStudioTools) => tools.searchScript('', 'pattern'), /Instance path and pattern/],
    ['getScriptFunction', (tools: RobloxStudioTools) => tools.getScriptFunction('game.Script', ''), /function name/],
    ['findAndReplaceInScripts paths', (tools: RobloxStudioTools) => tools.findAndReplaceInScripts([], 'a', 'b'), /Paths array/],
    [
      'findAndReplaceInScripts strings',
      (tools: RobloxStudioTools) => tools.findAndReplaceInScripts(['game.Script'], undefined as any, 'b'),
      /old_string and new_string/,
    ],
    ['getAttribute', (tools: RobloxStudioTools) => tools.getAttribute('', 'Health'), /Instance path and attribute name/],
    ['setAttribute', (tools: RobloxStudioTools) => tools.setAttribute('', 'Health', 1), /Instance path and attribute name/],
    ['getAttributes', (tools: RobloxStudioTools) => tools.getAttributes(''), /Instance path is required/],
    ['deleteAttribute', (tools: RobloxStudioTools) => tools.deleteAttribute('', 'Health'), /Instance path and attribute name/],
    ['getTags', (tools: RobloxStudioTools) => tools.getTags(''), /Instance path is required/],
    ['addTag', (tools: RobloxStudioTools) => tools.addTag('', 'Enemy'), /Instance path and tag name/],
    ['removeTag', (tools: RobloxStudioTools) => tools.removeTag('', 'Enemy'), /Instance path and tag name/],
    ['getTagged', (tools: RobloxStudioTools) => tools.getTagged(''), /Tag name is required/],
    ['cloneInstance', (tools: RobloxStudioTools) => tools.cloneInstance('', 'game'), /Source path and target parent/],
    ['moveInstance', (tools: RobloxStudioTools) => tools.moveInstance('', 'game'), /Instance path and new parent/],
    ['validateScript', (tools: RobloxStudioTools) => tools.validateScript(), /Either instance path or source/],
    ['insertAsset', (tools: RobloxStudioTools) => tools.insertAsset(0), /Asset ID is required/],
    ['renderObjectView', (tools: RobloxStudioTools) => tools.renderObjectView(''), /Instance path is required/],
    ['focusCamera', (tools: RobloxStudioTools) => tools.focusCamera(''), /Instance path is required/],
    ['executeLua', (tools: RobloxStudioTools) => tools.executeLua(''), /Code is required/],
    ['searchRobloxDocs', (tools: RobloxStudioTools) => tools.searchRobloxDocs(''), /query is required/],
    ['getRobloxDoc', (tools: RobloxStudioTools) => tools.getRobloxDoc(''), /path is required/],
    ['getRobloxApiReference', (tools: RobloxStudioTools) => tools.getRobloxApiReference(''), /name is required/],
  ])('%s rejects invalid input before bridge use', async (_name, call, message) => {
    const { bridge, tools } = setup();

    await expect(call(tools)).rejects.toThrow(message);
    expect(bridge.sendRequest).not.toHaveBeenCalled();
  });
});

describe('RobloxStudioTools MCP-internal companion guards', () => {
  test.each([
    ['deleteObject', (tools: RobloxStudioTools) => tools.deleteObject('game.ServerScriptService._MCPTestCompanion')],
    ['setScriptSource', (tools: RobloxStudioTools) => tools.setScriptSource('game.ServerScriptService._MCPTestCompanion', 'print(1)')],
    ['editScript', (tools: RobloxStudioTools) => tools.editScript('game.ServerScriptService._MCPTestCompanion', 'a', 'b')],
    ['cloneInstance', (tools: RobloxStudioTools) => tools.cloneInstance('game.ServerScriptService._MCPTestCompanion', 'game.Workspace')],
    ['moveInstance', (tools: RobloxStudioTools) => tools.moveInstance('game.ServerScriptService._MCPTestCompanion', 'game.Workspace')],
  ])('%s refuses to mutate companion scripts', async (_name, call) => {
    const { bridge, tools } = setup();

    const body = parseToolText(await call(tools));

    expect(body).toMatchObject({ success: false, error: 'mcp_internal' });
    expect(body.message).toContain('_MCPTestCompanion');
    expect(bridge.sendRequest).not.toHaveBeenCalled();
  });

  test('setProperty only blocks dangerous properties on companion scripts', async () => {
    const { bridge, tools } = setup();

    const blocked = parseToolText(
      await tools.setProperty('game.ServerScriptService._MCPTestCompanion', 'Disabled', true),
    );
    expect(blocked).toMatchObject({ success: false, error: 'mcp_internal' });
    expect(bridge.sendRequest).not.toHaveBeenCalled();

    await tools.setProperty('game.ServerScriptService._MCPTestCompanion', 'DisplayName', 'ok');
    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/set-property', {
      instancePath: 'game.ServerScriptService._MCPTestCompanion',
      propertyName: 'DisplayName',
      propertyValue: 'ok',
    });
  });

  test('findAndReplaceInScripts skips companion scripts but still edits allowed scripts', async () => {
    const { bridge, tools } = setup({ success: true, changed: 1 });

    const body = parseToolText(
      await tools.findAndReplaceInScripts(
        ['game.ServerScriptService._MCPTestCompanion', 'game.ServerScriptService.Main'],
        'old',
        'new',
      ),
    );

    expect(bridge.sendRequest).toHaveBeenCalledWith('/api/find-and-replace-in-scripts', {
      paths: ['game.ServerScriptService.Main'],
      oldString: 'old',
      newString: 'new',
      validateAfter: true,
    });
    expect(body).toMatchObject({
      success: true,
      changed: 1,
      skippedMCPInternal: ['game.ServerScriptService._MCPTestCompanion'],
    });
  });

  test('findAndReplaceInScripts refuses all-companion batches', async () => {
    const { bridge, tools } = setup();

    const body = parseToolText(
      await tools.findAndReplaceInScripts(['game.StarterPlayer._MCPTestCompanion_Client'], 'old', 'new'),
    );

    expect(body).toMatchObject({ success: false, error: 'mcp_internal' });
    expect(bridge.sendRequest).not.toHaveBeenCalled();
  });
});
