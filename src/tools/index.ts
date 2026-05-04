import { StudioHttpClient } from './studio-client.js';
import { BridgeService } from '../bridge-service.js';
import * as zlib from 'zlib';
import { ensureDocsCache } from '../docs/fetcher.js';
import {
  listDocs,
  readDocFile,
  searchDocs,
  type ListOptions,
  type SearchOptions,
} from '../docs/search.js';
import { resolveReference, type ReferenceCategory } from '../docs/reference.js';

// PNG encoding utilities
function createPNG(rgbaData: Buffer, width: number, height: number): Buffer {
  // PNG signature
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR chunk
  const ihdr = createIHDRChunk(width, height);

  // IDAT chunk (compressed image data)
  const idat = createIDATChunk(rgbaData, width, height);

  // IEND chunk
  const iend = createIENDChunk();

  return Buffer.concat([signature, ihdr, idat, iend]);
}

function createChunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);

  const typeBuffer = Buffer.from(type, 'ascii');
  const crcData = Buffer.concat([typeBuffer, data]);

  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(crcData), 0);

  return Buffer.concat([length, typeBuffer, data, crc]);
}

function createIHDRChunk(width: number, height: number): Buffer {
  const data = Buffer.alloc(13);
  data.writeUInt32BE(width, 0);      // Width
  data.writeUInt32BE(height, 4);     // Height
  data.writeUInt8(8, 8);             // Bit depth
  data.writeUInt8(6, 9);             // Color type (RGBA)
  data.writeUInt8(0, 10);            // Compression method
  data.writeUInt8(0, 11);            // Filter method
  data.writeUInt8(0, 12);            // Interlace method

  return createChunk('IHDR', data);
}

function createIDATChunk(rgbaData: Buffer, width: number, height: number): Buffer {
  // Add filter byte (0 = None) at the start of each row
  const rowSize = width * 4;
  const filteredData = Buffer.alloc(height * (rowSize + 1));

  for (let y = 0; y < height; y++) {
    filteredData[y * (rowSize + 1)] = 0; // Filter type: None
    rgbaData.copy(filteredData, y * (rowSize + 1) + 1, y * rowSize, (y + 1) * rowSize);
  }

  // Compress with zlib
  const compressed = zlib.deflateSync(filteredData, { level: 6 });

  return createChunk('IDAT', compressed);
}

function createIENDChunk(): Buffer {
  return createChunk('IEND', Buffer.alloc(0));
}

// CRC32 lookup table
const crcTable: number[] = [];
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) {
    c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  }
  crcTable[n] = c >>> 0;
}

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = crcTable[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export class RobloxStudioTools {
  private client: StudioHttpClient;
  private bridge: BridgeService;

  constructor(bridge: BridgeService) {
    this.bridge = bridge;
    this.client = new StudioHttpClient(bridge);
  }

  // File System Tools
  async getFileTree(path: string = '') {
    const response = await this.client.request('/api/file-tree', { path });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async searchFiles(query: string, searchType: string = 'name') {
    const response = await this.client.request('/api/search-files', { query, searchType });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Studio Context Tools
  async getPlaceInfo() {
    const response = await this.client.request('/api/place-info', {});
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getServices(serviceName?: string) {
    const response = await this.client.request('/api/services', { serviceName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async searchObjects(query: string, searchType: string = 'name', propertyName?: string) {
    const response = await this.client.request('/api/search-objects', { 
      query, 
      searchType, 
      propertyName 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Property & Instance Tools
  async getInstanceProperties(instancePath: string) {
    if (!instancePath) {
      throw new Error('Instance path is required for get_instance_properties');
    }
    const response = await this.client.request('/api/instance-properties', { instancePath });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getInstanceChildren(instancePath: string) {
    if (!instancePath) {
      throw new Error('Instance path is required for get_instance_children');
    }
    const response = await this.client.request('/api/instance-children', { instancePath });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async searchByProperty(propertyName: string, propertyValue: string) {
    if (!propertyName || !propertyValue) {
      throw new Error('Property name and value are required for search_by_property');
    }
    const response = await this.client.request('/api/search-by-property', { 
      propertyName, 
      propertyValue 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getClassInfo(className: string) {
    if (!className) {
      throw new Error('Class name is required for get_class_info');
    }
    const response = await this.client.request('/api/class-info', { className });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Project Tools
  async getProjectStructure(path?: string, maxDepth?: number, scriptsOnly?: boolean) {
    const response = await this.client.request('/api/project-structure', { 
      path, 
      maxDepth, 
      scriptsOnly 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }


  // Property Modification Tools
  async setProperty(instancePath: string, propertyName: string, propertyValue: any) {
    if (!instancePath || !propertyName) {
      throw new Error('Instance path and property name are required for set_property');
    }
    const response = await this.client.request('/api/set-property', { 
      instancePath, 
      propertyName, 
      propertyValue 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async massSetProperty(paths: string[], propertyName: string, propertyValue: any) {
    if (!paths || paths.length === 0 || !propertyName) {
      throw new Error('Paths array and property name are required for mass_set_property');
    }
    const response = await this.client.request('/api/mass-set-property', { 
      paths, 
      propertyName, 
      propertyValue 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async massGetProperty(paths: string[], propertyName: string) {
    if (!paths || paths.length === 0 || !propertyName) {
      throw new Error('Paths array and property name are required for mass_get_property');
    }
    const response = await this.client.request('/api/mass-get-property', { 
      paths, 
      propertyName
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Object Creation Tools
  async createObject(className: string, parent: string, name?: string) {
    if (!className || !parent) {
      throw new Error('Class name and parent are required for create_object');
    }
    const response = await this.client.request('/api/create-object', { 
      className, 
      parent, 
      name
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async createObjectWithProperties(className: string, parent: string, name?: string, properties?: Record<string, any>) {
    if (!className || !parent) {
      throw new Error('Class name and parent are required for create_object_with_properties');
    }
    const response = await this.client.request('/api/create-object', { 
      className, 
      parent, 
      name, 
      properties 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async massCreateObjects(objects: Array<{className: string, parent: string, name?: string}>) {
    if (!objects || objects.length === 0) {
      throw new Error('Objects array is required for mass_create_objects');
    }
    const response = await this.client.request('/api/mass-create-objects', { objects });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async massCreateObjectsWithProperties(objects: Array<{className: string, parent: string, name?: string, properties?: Record<string, any>}>) {
    if (!objects || objects.length === 0) {
      throw new Error('Objects array is required for mass_create_objects_with_properties');
    }
    const response = await this.client.request('/api/mass-create-objects-with-properties', { objects });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async deleteObject(instancePath: string) {
    if (!instancePath) {
      throw new Error('Instance path is required for delete_object');
    }
    const response = await this.client.request('/api/delete-object', { instancePath });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Smart Duplication Tools
  async smartDuplicate(
    instancePath: string, 
    count: number, 
    options?: {
      namePattern?: string; // e.g., "Button{n}" where {n} is replaced with index
      positionOffset?: [number, number, number]; // X, Y, Z offset per duplicate
      rotationOffset?: [number, number, number]; // X, Y, Z rotation offset per duplicate
      scaleOffset?: [number, number, number]; // X, Y, Z scale multiplier per duplicate
      propertyVariations?: Record<string, any[]>; // Property name to array of values
      targetParents?: string[]; // Different parent for each duplicate
    }
  ) {
    if (!instancePath || count < 1) {
      throw new Error('Instance path and count > 0 are required for smart_duplicate');
    }
    const response = await this.client.request('/api/smart-duplicate', { 
      instancePath, 
      count, 
      options 
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async massDuplicate(
    duplications: Array<{
      instancePath: string;
      count: number;
      options?: {
        namePattern?: string;
        positionOffset?: [number, number, number];
        rotationOffset?: [number, number, number];
        scaleOffset?: [number, number, number];
        propertyVariations?: Record<string, any[]>;
        targetParents?: string[];
      }
    }>
  ) {
    if (!duplications || duplications.length === 0) {
      throw new Error('Duplications array is required for mass_duplicate');
    }
    const response = await this.client.request('/api/mass-duplicate', { duplications });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Calculated Property Tools
  async setCalculatedProperty(
    paths: string[], 
    propertyName: string, 
    formula: string,
    variables?: Record<string, any>
  ) {
    if (!paths || paths.length === 0 || !propertyName || !formula) {
      throw new Error('Paths, property name, and formula are required for set_calculated_property');
    }
    const response = await this.client.request('/api/set-calculated-property', { 
      paths, 
      propertyName, 
      formula,
      variables
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Relative Property Tools
  async setRelativeProperty(
    paths: string[], 
    propertyName: string, 
    operation: 'add' | 'multiply' | 'divide' | 'subtract' | 'power',
    value: any,
    component?: 'X' | 'Y' | 'Z' // For Vector3/UDim2 properties
  ) {
    if (!paths || paths.length === 0 || !propertyName || !operation || value === undefined) {
      throw new Error('Paths, property name, operation, and value are required for set_relative_property');
    }
    const response = await this.client.request('/api/set-relative-property', { 
      paths, 
      propertyName, 
      operation,
      value,
      component
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // SCRIPT MANAGEMENT TOOLS
  //
  // The legacy line-based partial editors (edit_script_lines /
  // insert_script_lines / delete_script_lines) were removed in favor of
  // the string-based editScript() below — line numbers shift after every
  // edit, which makes line-based editing unreliable for AI workflows.
  // ============================================

  async getScriptSource(instancePath: string, startLine?: number, endLine?: number) {
    if (!instancePath) {
      throw new Error('Instance path is required for get_script_source');
    }
    const response = await this.client.request('/api/get-script-source', { instancePath, startLine, endLine });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async setScriptSource(instancePath: string, source: string) {
    if (!instancePath || typeof source !== 'string') {
      throw new Error('Instance path and source code string are required for set_script_source');
    }
    const response = await this.client.request('/api/set-script-source', { instancePath, source });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  /**
   * edit_script - String-based script editing like Claude Code's Edit tool.
   * Find exact text and replace it - no line numbers needed.
   */
  async editScript(instancePath: string, oldString: string, newString: string, replaceAll: boolean = false, validateAfter: boolean = true) {
    if (!instancePath) {
      throw new Error('Instance path is required for edit_script');
    }
    if (typeof oldString !== 'string') {
      throw new Error('old_string is required for edit_script');
    }
    if (typeof newString !== 'string') {
      throw new Error('new_string is required for edit_script');
    }
    if (oldString === newString) {
      throw new Error('old_string and new_string must be different');
    }

    const response = await this.client.request('/api/edit-script', {
      instancePath,
      oldString,
      newString,
      replaceAll,
      validateAfter
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  /**
   * search_script - Search for patterns within a script (like grep).
   */
  async searchScript(instancePath: string, pattern: string, useRegex: boolean = false, contextLines: number = 0) {
    if (!instancePath || !pattern) {
      throw new Error('Instance path and pattern are required for search_script');
    }
    const response = await this.client.request('/api/search-script', {
      instancePath,
      pattern,
      useRegex,
      contextLines
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  /**
   * get_script_function - Extract a specific function from a script by name.
   */
  async getScriptFunction(instancePath: string, functionName: string) {
    if (!instancePath || !functionName) {
      throw new Error('Instance path and function name are required for get_script_function');
    }
    const response = await this.client.request('/api/get-script-function', {
      instancePath,
      functionName
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  /**
   * find_and_replace_in_scripts - Batch find-and-replace across multiple scripts.
   */
  async findAndReplaceInScripts(paths: string[], oldString: string, newString: string, validateAfter: boolean = true) {
    if (!paths || paths.length === 0) {
      throw new Error('Paths array is required for find_and_replace_in_scripts');
    }
    if (typeof oldString !== 'string' || typeof newString !== 'string') {
      throw new Error('old_string and new_string are required');
    }

    const response = await this.client.request('/api/find-and-replace-in-scripts', {
      paths,
      oldString,
      newString,
      validateAfter
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Attribute Tools
  async getAttribute(instancePath: string, attributeName: string) {
    if (!instancePath || !attributeName) {
      throw new Error('Instance path and attribute name are required for get_attribute');
    }
    const response = await this.client.request('/api/get-attribute', { instancePath, attributeName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async setAttribute(instancePath: string, attributeName: string, attributeValue: any, valueType?: string) {
    if (!instancePath || !attributeName) {
      throw new Error('Instance path and attribute name are required for set_attribute');
    }
    const response = await this.client.request('/api/set-attribute', { instancePath, attributeName, attributeValue, valueType });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getAttributes(instancePath: string) {
    if (!instancePath) {
      throw new Error('Instance path is required for get_attributes');
    }
    const response = await this.client.request('/api/get-attributes', { instancePath });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async deleteAttribute(instancePath: string, attributeName: string) {
    if (!instancePath || !attributeName) {
      throw new Error('Instance path and attribute name are required for delete_attribute');
    }
    const response = await this.client.request('/api/delete-attribute', { instancePath, attributeName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // Tag Tools (CollectionService)
  async getTags(instancePath: string) {
    if (!instancePath) {
      throw new Error('Instance path is required for get_tags');
    }
    const response = await this.client.request('/api/get-tags', { instancePath });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async addTag(instancePath: string, tagName: string) {
    if (!instancePath || !tagName) {
      throw new Error('Instance path and tag name are required for add_tag');
    }
    const response = await this.client.request('/api/add-tag', { instancePath, tagName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async removeTag(instancePath: string, tagName: string) {
    if (!instancePath || !tagName) {
      throw new Error('Instance path and tag name are required for remove_tag');
    }
    const response = await this.client.request('/api/remove-tag', { instancePath, tagName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getTagged(tagName: string) {
    if (!tagName) {
      throw new Error('Tag name is required for get_tagged');
    }
    const response = await this.client.request('/api/get-tagged', { tagName });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async getSelection() {
    const response = await this.client.request('/api/get-selection', {});
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // OUTPUT CAPTURE TOOL
  // ============================================

  async getOutput(limit?: number, since?: number, messageTypes?: string[], clear?: boolean) {
    const response = await this.client.request('/api/get-output', {
      limit,
      since,
      messageTypes,
      clear
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // INSTANCE MANIPULATION TOOLS (clone, move)
  // ============================================

  async cloneInstance(sourcePath: string, targetParent: string, newName?: string) {
    if (!sourcePath || !targetParent) {
      throw new Error('Source path and target parent are required for clone_instance');
    }
    const response = await this.client.request('/api/clone-instance', {
      sourcePath,
      targetParent,
      newName
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async moveInstance(instancePath: string, newParent: string) {
    if (!instancePath || !newParent) {
      throw new Error('Instance path and new parent are required for move_instance');
    }
    const response = await this.client.request('/api/move-instance', {
      instancePath,
      newParent
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // SCRIPT VALIDATION TOOL
  // ============================================

  async validateScript(instancePath?: string, source?: string) {
    if (!instancePath && !source) {
      throw new Error('Either instance path or source code is required for validate_script');
    }
    const response = await this.client.request('/api/validate-script', {
      instancePath,
      source
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // UNDO/REDO TOOLS
  // ============================================

  async undo() {
    const response = await this.client.request('/api/undo', {});
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  async redo() {
    const response = await this.client.request('/api/redo', {});
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // ASSET INSERTION TOOL (Creator Store)
  // ============================================

  async insertAsset(assetId: number, folderName?: string, targetParent?: string) {
    if (!assetId) {
      throw new Error('Asset ID is required for insert_asset');
    }
    const response = await this.client.request('/api/insert-asset', {
      assetId,
      folderName,
      targetParent
    });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // PLAYTEST CONTROL TOOLS
  //
  // play_solo / stop_play / get_playtest_output coordinate three actors:
  //   1. This MCP server (Node)
  //   2. The Edit-side plugin (calls ExecutePlayModeAsync, which yields
  //      until the test ends)
  //   3. The companion Script injected into the test's Server DataModel
  //      (the only place EndTest() is allowed to be called from)
  //
  // play_solo:    bridge generates sessionId → plugin embeds it in companion
  //               → companion polls bridge for commands while test runs
  // stop_play:    bridge enqueues "end" command → companion picks it up
  //               and calls StudioTestService:EndTest()
  // get_playtest_output: reads the bridge's buffered log entries that the
  //               companion streamed up during the test
  // ============================================

  async playSolo() {
    // If a session is still marked active (e.g. previous test was force-
    // killed by the user clicking Stop without us hearing about it, or a
    // restart was requested), signal stop and wait briefly so the new run
    // doesn't race the old companion.
    if (this.bridge.testSession?.status === 'active') {
      this.bridge.enqueueTestCommand({ cmd: 'end', args: 'MCP_Restart' });
      await this.bridge.waitForTestEnd(3000);
    }

    const sessionId = this.bridge.startTestSession();
    let response: any;
    try {
      response = await this.client.request('/api/play-solo', { sessionId });
    } catch (err) {
      // The plugin failed to acknowledge — drop our session so we don't
      // leave it dangling.
      this.bridge.endTestSession(sessionId, 'plugin_request_failed');
      throw err;
    }

    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify({
            ...response,
            sessionId,
            note: 'Use get_playtest_output to read logs; stop_play to end.',
          }, null, 2),
        },
      ],
    };
  }

  async stopPlay() {
    const session = this.bridge.testSession;
    if (!session) {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            success: true,
            alreadyEnded: true,
            message: 'No play test session is tracked. Nothing to stop.',
          }, null, 2),
        }],
      };
    }
    if (session.status === 'ended') {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            success: true,
            alreadyEnded: true,
            sessionId: session.sessionId,
            endReason: session.endReason,
            message: `Play test already ended (${session.endReason}).`,
          }, null, 2),
        }],
      };
    }

    const queued = this.bridge.enqueueTestCommand({ cmd: 'end', args: 'MCP_Stop' });
    if (!queued) {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            success: false,
            error: 'Failed to enqueue stop command (no active session).',
          }, null, 2),
        }],
      };
    }

    // Companion polls every ~400ms; allow a generous window for HTTP RTT
    // and EndTest to actually complete. We also accept the case where the
    // user's companion is dead (HTTP disabled, etc.) — return a clear
    // signaled-but-unconfirmed state so the AI can fall back to telling
    // the user to click Stop manually.
    const ended = await this.bridge.waitForTestEnd(8000);
    const after = this.bridge.testSession;

    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          success: true,
          confirmed: ended,
          sessionId: session.sessionId,
          status: after?.status ?? 'unknown',
          endReason: after?.endReason ?? null,
          message: ended
            ? 'Play test stopped via StudioTestService:EndTest().'
            : 'Stop signal sent but the in-test companion did not confirm within 8s. The test may still end shortly, or the companion may not be reachable (e.g. HTTP disabled in test). If the test is still running, click Stop in Studio.',
        }, null, 2),
      }],
    };
  }

  /**
   * Read output captured during the most recent play test session. Output
   * is collected by the companion Script via LogService.MessageOut while
   * the test is running, and remains queryable after the session ends.
   *
   * Use the `since` cursor (returned as `nextSinceSeq`) to incrementally
   * tail logs without re-reading what you've already seen.
   */
  async getPlaytestOutput(sinceSeq?: number, limit?: number, messageTypes?: string[]) {
    const result = this.bridge.getTestOutput({
      sinceSeq,
      limit,
      messageTypes,
    });
    return {
      content: [{
        type: 'text',
        text: JSON.stringify(result, null, 2),
      }],
    };
  }

  // ============================================
  // SCREENSHOT TOOL
  // ============================================

  async captureScreenshot(maxWidth?: number, maxHeight?: number) {
    const response = await this.client.request('/api/capture-screenshot', {
      maxWidth: maxWidth || 768,
      maxHeight: maxHeight || 768,
      returnBase64: true
    });

    // If we have base64 RGBA data, convert it to PNG for proper image viewing
    const responseData = response as any;
    if (responseData.success && responseData.base64) {
      try {
        // Decode base64 RGBA data from Lua
        const rgbaBuffer = Buffer.from(responseData.base64, 'base64');
        const width = responseData.width;
        const height = responseData.height;

        // Validate buffer size matches dimensions
        const expectedSize = width * height * 4;
        if (rgbaBuffer.length !== expectedSize) {
          throw new Error(`Buffer size mismatch: got ${rgbaBuffer.length}, expected ${expectedSize} for ${width}x${height}`);
        }

        // Convert RGBA to PNG
        const pngBuffer = createPNG(rgbaBuffer, width, height);
        const pngBase64 = pngBuffer.toString('base64');

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                success: true,
                message: responseData.message,
                originalWidth: responseData.originalWidth,
                originalHeight: responseData.originalHeight,
                width: width,
                height: height,
                format: 'PNG',
                note: "Screenshot captured and converted to PNG format."
              }, null, 2)
            },
            {
              type: 'image',
              data: pngBase64,
              mimeType: 'image/png'
            }
          ]
        };
      } catch (err) {
        // If PNG conversion fails, return error info
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                success: false,
                error: `PNG conversion failed: ${err instanceof Error ? err.message : String(err)}`,
                originalResponse: responseData
              }, null, 2)
            }
          ]
        };
      }
    }

    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // VIEWPORTFRAME RENDERING SYSTEM
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
      resolution: options?.resolution || { width: 768, height: 768 },
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

  // ============================================
  // CAMERA CONTROL SYSTEM
  // ============================================

  /**
   * focus_camera - Position Studio camera to focus on an object (like pressing F)
   * Works with any object size and supports all angle presets
   */
  async focusCamera(
    instancePath: string,
    options?: {
      angle?: string | { pitch?: number; yaw?: number; roll?: number };
      distance?: number;
      autoDistance?: boolean;
    }
  ) {
    if (!instancePath) {
      throw new Error('Instance path is required for focus_camera');
    }

    const response = await this.client.request('/api/focus-camera', {
      instancePath,
      angle: options?.angle || 'iso',
      distance: options?.distance,
      autoDistance: options?.autoDistance !== false,
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
  // EXECUTE LUA TOOL
  // ============================================

  async executeLua(code: string) {
    if (!code) {
      throw new Error('Code is required for execute_lua');
    }
    const response = await this.client.request('/api/execute-lua', { code });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2)
        }
      ]
    };
  }

  // ============================================
  // ROBLOX CREATOR-DOCS TOOLS
  //
  // These tools mirror github.com/Roblox/creator-docs to a local cache
  // and let the model search/read it like a local repo. They do NOT go
  // through the Studio HTTP bridge — they're pure server-side.
  //
  // The cache is downloaded lazily on first use (~5s, ~30MB) and
  // refreshed at most once every 24h with a SHA short-circuit. See
  // src/docs/fetcher.ts for the strategy.
  // ============================================

  async searchRobloxDocs(query: string, options: SearchOptions = {}) {
    if (!query || typeof query !== 'string') {
      throw new Error('query is required for search_roblox_docs');
    }
    const ensured = await ensureDocsCache();
    const summary = await searchDocs(ensured.cacheDir, query, options);
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              cache: {
                action: ensured.action,
                sha: ensured.meta.sha,
                downloadedAt: ensured.meta.downloadedAt,
                durationMs: ensured.durationMs,
              },
              query,
              options,
              ...summary,
            },
            null,
            2,
          ),
        },
      ],
    };
  }

  async getRobloxDoc(relPath: string) {
    if (!relPath || typeof relPath !== 'string') {
      throw new Error('path is required for get_roblox_doc');
    }
    const ensured = await ensureDocsCache();
    const doc = await readDocFile(ensured.cacheDir, relPath);
    if (!doc) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                error: `Doc not found: "${relPath}". Use list_roblox_docs to discover paths, or search_roblox_docs to find a hit.`,
                cache: {
                  sha: ensured.meta.sha,
                  fileCount: ensured.meta.fileCount,
                  cacheDir: ensured.cacheDir,
                },
              },
              null,
              2,
            ),
          },
        ],
      };
    }
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              path: doc.path,
              bytes: doc.bytes,
              cache: {
                action: ensured.action,
                sha: ensured.meta.sha,
              },
              content: doc.content,
            },
            null,
            2,
          ),
        },
      ],
    };
  }

  async listRobloxDocs(relPath: string = '', options: ListOptions = {}) {
    const ensured = await ensureDocsCache();
    const listing = await listDocs(ensured.cacheDir, relPath, options);
    if (!listing) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                error: `Path not found: "${relPath}".`,
                cache: { sha: ensured.meta.sha, fileCount: ensured.meta.fileCount },
              },
              null,
              2,
            ),
          },
        ],
      };
    }
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              cache: {
                action: ensured.action,
                sha: ensured.meta.sha,
              },
              ...listing,
            },
            null,
            2,
          ),
        },
      ],
    };
  }

  async getRobloxApiReference(name: string, category?: ReferenceCategory) {
    if (!name || typeof name !== 'string') {
      throw new Error('name is required for get_roblox_api_reference');
    }
    const ensured = await ensureDocsCache();
    const result = await resolveReference(ensured.cacheDir, name, category);
    if (!result) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                error: `No API reference found for "${name}"${category ? ` in category "${category}"` : ''}. Try search_roblox_docs to find similar names.`,
                cache: { sha: ensured.meta.sha, fileCount: ensured.meta.fileCount },
              },
              null,
              2,
            ),
          },
        ],
      };
    }
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              cache: {
                action: ensured.action,
                sha: ensured.meta.sha,
              },
              ...result,
            },
            null,
            2,
          ),
        },
      ],
    };
  }

}