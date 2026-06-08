import { StudioHttpClient } from './studio-client.js';
import { BridgeService } from '../bridge-service.js';
import * as zlib from 'zlib';
import { v4 as uuidv4 } from 'uuid';
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

  // ============================================
  // MCP-INTERNAL SAFETY GUARDS
  //
  // run_live_lua relies on injected companion Scripts that live in
  // ServerScriptService and StarterPlayer.StarterPlayerScripts. We don't
  // want a confused AI to accidentally delete/edit/disable them via the
  // generic destructive tools (set_property, delete_object, set_script_source,
  // edit_script, find_and_replace_in_scripts, move_instance) — those would
  // silently break the bridge.
  //
  // The plugin already does opportunistic sweeping by tag/name on activate
  // and at the start/end of each play_solo. This guard is the second layer:
  // refuse the operation outright with a friendly explanation, so the AI
  // gets explicit feedback instead of mysterious "no eval reply" errors.
  // ============================================
  private static readonly MCP_INTERNAL_NAMES = [
    '_MCPTestCompanion',
    '_MCPTestCompanion_Client',
  ];

  private isMCPInternal(path: string | undefined | null): boolean {
    if (!path || typeof path !== 'string') return false;
    for (const name of RobloxStudioTools.MCP_INTERNAL_NAMES) {
      // Match as a path segment (preceded/followed by '.' or end-of-string),
      // not as a substring inside an arbitrary user-named instance.
      if (
        path === name ||
        path.endsWith('.' + name) ||
        path.includes('.' + name + '.') ||
        path.startsWith(name + '.')
      ) {
        return true;
      }
    }
    return false;
  }

  private mcpInternalRefusal(action: string, instancePath: string) {
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              success: false,
              error: 'mcp_internal',
              message: `Refusing to ${action} "${instancePath}" — this is an MCP-internal companion Script used by run_live_lua / play_solo. The plugin manages its lifecycle automatically; if you really want it gone, run stop_play and the plugin will sweep it on the next activation. (Names reserved: _MCPTestCompanion, _MCPTestCompanion_Client.)`,
            },
            null,
            2,
          ),
        },
      ],
    };
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

  /**
   * grep — Claude Code-style search across the instance tree.
   *
   * Forwards to the Studio plugin which does a single `GetDescendants` walk
   * scoped to `path`, filters by `type` (via `IsA`) and `glob` (Lua pattern
   * over Name), then scans `Source` line-by-line (or full-source if
   * `multiline`) for `pattern`. Designed to mirror the parameter surface of
   * Claude Code's Grep tool 1:1 so the LLM can reuse muscle memory.
   */
  async grep(
    pattern: string,
    options: {
      path?: string;
      glob?: string;
      type?: string[];
      caseInsensitive?: boolean;
      after?: number;
      before?: number;
      context?: number;
      outputMode?: 'files_with_matches' | 'content' | 'count';
      headLimit?: number;
      multiline?: boolean;
    } = {}
  ) {
    if (typeof pattern !== 'string' || pattern.length === 0) {
      throw new Error('pattern is required for grep (use ".*" for name-only searches)');
    }
    const response = await this.client.request('/api/grep', {
      pattern,
      path: options.path ?? 'game',
      glob: options.glob,
      type: options.type ?? ['LuaSourceContainer'],
      caseInsensitive: options.caseInsensitive ?? false,
      after: options.after ?? 0,
      before: options.before ?? 0,
      context: options.context ?? 0,
      outputMode: options.outputMode ?? 'files_with_matches',
      headLimit: options.headLimit ?? 0,
      multiline: options.multiline ?? false,
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


  // Property Modification Tools
  async setProperty(instancePath: string, propertyName: string, propertyValue: any) {
    if (!instancePath || !propertyName) {
      throw new Error('Instance path and property name are required for set_property');
    }
    // Refuse to mutate MCP-internal companions — only the destructive
    // properties; reading/altering benign metadata (e.g. Source via the
    // dedicated API) is already gated below.
    if (this.isMCPInternal(instancePath)) {
      const dangerous = new Set([
        'Disabled', 'Source', 'Parent', 'Name', 'Archivable', 'RunContext', 'Enabled',
      ]);
      if (dangerous.has(propertyName)) {
        return this.mcpInternalRefusal(`set ${propertyName} on`, instancePath);
      }
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
    if (this.isMCPInternal(instancePath)) {
      return this.mcpInternalRefusal('delete', instancePath);
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
    if (this.isMCPInternal(instancePath)) {
      return this.mcpInternalRefusal('rewrite source of', instancePath);
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
    if (this.isMCPInternal(instancePath)) {
      return this.mcpInternalRefusal('edit', instancePath);
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

    // Filter out MCP-internal paths and report which ones we skipped, so
    // the AI doesn't silently include companions in a batch rename.
    const blocked: string[] = [];
    const allowed: string[] = [];
    for (const p of paths) {
      if (this.isMCPInternal(p)) {
        blocked.push(p);
      } else {
        allowed.push(p);
      }
    }
    if (allowed.length === 0) {
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify({
              success: false,
              error: 'mcp_internal',
              message: `All targeted paths are MCP-internal companion Scripts. Refusing to edit. Blocked: ${blocked.join(', ')}`,
            }, null, 2),
          },
        ],
      };
    }

    const response = await this.client.request('/api/find-and-replace-in-scripts', {
      paths: allowed,
      oldString,
      newString,
      validateAfter
    });
    if (blocked.length > 0) {
      const responseObj = response as any;
      responseObj.skippedMCPInternal = blocked;
      responseObj.note = `${blocked.length} MCP-internal companion Script(s) were skipped: ${blocked.join(', ')}`;
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
    if (this.isMCPInternal(sourcePath)) {
      return this.mcpInternalRefusal('clone', sourcePath);
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
    if (this.isMCPInternal(instancePath)) {
      return this.mcpInternalRefusal('move', instancePath);
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

  async undo(count?: number) {
    // Default + clamp client-side so the plugin can stay strict. Studio's
    // own undo stack is the real source of truth; the plugin stops early if
    // it runs out, regardless of what we ask for.
    const safeCount =
      typeof count === 'number' && Number.isFinite(count)
        ? Math.max(1, Math.min(100, Math.floor(count)))
        : 1;
    const response = await this.client.request('/api/undo', { count: safeCount });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2),
        },
      ],
    };
  }

  async redo(count?: number) {
    const safeCount =
      typeof count === 'number' && Number.isFinite(count)
        ? Math.max(1, Math.min(100, Math.floor(count)))
        : 1;
    const response = await this.client.request('/api/redo', { count: safeCount });
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(response, null, 2),
        },
      ],
    };
  }

  async getHistory(limit?: number, includeDetails?: boolean) {
    // 20 is a sweet spot: enough for "what did I just do?" recall without
    // bloating context. Plugin caps at MAX_ACTION_HISTORY (100).
    const safeLimit =
      typeof limit === 'number' && Number.isFinite(limit)
        ? Math.max(1, Math.min(100, Math.floor(limit)))
        : 20;
    const response = await this.client.request('/api/get-history', {
      limit: safeLimit,
      includeDetails: includeDetails === true,
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
  // RUN_LIVE_LUA — execute code inside the running play test
  //
  // Flow:
  //   1. Pre-flight: bridge.getTestSessionStatus() — fail fast with a
  //      structured `error` field (no thrown exception) for the common
  //      cases the AI needs to handle differently (no playtest, ended,
  //      companion not yet connected, no clients on a client-target call,
  //      loadstring disabled).
  //   2. Generate a replyId, register a watchdog slot.
  //   3. Enqueue an "eval" command on the appropriate companion's queue.
  //      The companion picks it up on its next poll (~400ms cadence),
  //      runs it under loadstring + xpcall + LogService capture, then
  //      POSTs the result to /test-session/eval-result.
  //   4. Await the slot — resolves with the companion's reply, or with a
  //      synthetic timeout / companion_error if the watchdog fires.
  //
  // This method NEVER throws — all failure paths come back as
  // `{ success: false, error: <enum>, message: ... }` so the AI can branch
  // on the error type without try/catch ceremony.
  // ============================================

  async runLiveLua(
    code: string,
    target: 'server' | 'client' = 'server',
    playerName?: string,
    timeoutMs: number = 5000,
    captureLogs: boolean = true
  ) {
    // Helper to wrap structured failures consistently.
    const fail = (
      error: string,
      message: string,
      extra: Record<string, any> = {}
    ) => ({
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            { success: false, error, message, target, ...extra },
            null,
            2
          ),
        },
      ],
    });

    // ---- Argument validation (still no throws — friendly errors) -------
    if (typeof code !== 'string' || code.length === 0) {
      return fail('invalid_args', 'code is required and must be a non-empty string.');
    }
    if (target !== 'server' && target !== 'client') {
      return fail('invalid_args', `target must be "server" or "client", got "${target}".`);
    }
    const tMs = Math.max(1000, Math.min(30000, Math.floor(Number(timeoutMs) || 5000)));

    // ---- Pre-flight on the bridge state --------------------------------
    const status = this.bridge.getTestSessionStatus();
    if (!status) {
      return fail(
        'no_playtest',
        'No play test is running. Call play_solo first to start one, then retry run_live_lua.'
      );
    }
    if (status.status === 'ended') {
      return fail(
        'playtest_ended',
        `The play test has already ended. Start a new one with play_solo before running live code.`
      );
    }

    // ---- Resolve target slot -------------------------------------------
    // Architecture note: HttpService is server-only in Roblox, so the client
    // companion CANNOT POST eval-results directly. Instead, target='client'
    // commands ride the SERVER queue with a `forwardTo` metadata field; the
    // server companion picks them up, dispatches via clientRelay:InvokeClient,
    // and POSTs the result on the client's behalf. This means the bridge's
    // reply slot is always 'server' regardless of logical target.
    let resolvedClientName: string | null = null;
    let resolvedClientUserId: number | null = null;
    const evalArgs: Record<string, any> = {
      // replyId added below
      code,
      timeoutMs: tMs,
      captureLogs: !!captureLogs,
    };

    if (target === 'server') {
      if (!status.serverReady) {
        return fail(
          'companion_not_ready',
          'Server companion has not connected yet. The play test was started but the in-test Script has not made its first poll. Wait ~1s and retry.'
        );
      }
      if (!status.serverLoadstringReady) {
        return fail(
          'loadstring_disabled',
          'ServerScriptService.LoadStringEnabled is false in this place, so the server companion cannot loadstring user code. Enable LoadStringEnabled in Studio (Game Settings → Security → Allow HTTP Requests / LoadString) BEFORE starting the test, then re-run play_solo.'
        );
      }
    } else {
      // target === 'client'
      const clients = status.clients;
      if (clients.length === 0) {
        return fail(
          'no_clients_connected',
          'No client companion has registered yet. Either no Player has joined the test, the LocalScript hasn\'t fired its hello RemoteEvent yet, or the server companion isn\'t set up. Wait briefly, or fall back to target="server".'
        );
      }
      let chosen = clients[0];
      if (playerName) {
        const match = clients.find(
          (c) => c.name === playerName || c.name.toLowerCase() === playerName.toLowerCase()
        );
        if (!match) {
          return fail(
            'no_such_player',
            `No connected client named "${playerName}". Connected players: ${clients
              .map((c) => `${c.name} (userId=${c.userId})`)
              .join(', ')}.`,
            { connectedClients: clients }
          );
        }
        chosen = match;
      } else if (clients.length > 1) {
        // Multi-client play test, ambiguous — bail loudly.
        return fail(
          'multiple_clients',
          `Multiple clients are connected; pass playerName to disambiguate. Connected: ${clients
            .map((c) => `${c.name} (userId=${c.userId})`)
            .join(', ')}.`,
          { connectedClients: clients }
        );
      }
      if (!chosen.ready) {
        return fail(
          'companion_not_ready',
          `Client companion for ${chosen.name} (userId=${chosen.userId}) has not finished its hello yet. Wait briefly and retry.`
        );
      }
      // Loadstring is core (always enabled in client LocalScripts), but we
      // surface the flag for completeness if the companion ever reports
      // false.
      if (!chosen.loadstringReady) {
        return fail(
          'loadstring_disabled',
          `Client companion for ${chosen.name} reported loadstring unavailable. (This is unusual on the client; check that the LocalScript was injected correctly.)`
        );
      }
      resolvedClientName = chosen.name;
      resolvedClientUserId = chosen.userId;
      // forwardTo tells the server companion to InvokeClient this player
      // instead of running the code locally on the server.
      evalArgs.forwardTo = { userId: chosen.userId, playerName: chosen.name };
    }

    // ---- Register slot, then enqueue the command ----------------------
    // Use the bridge's enqueue first because if it returns false we want
    // to skip allocating a watcher promise. But we need the replyId baked
    // into the enqueued args, so generate it up front.
    const replyId = uuidv4();
    evalArgs.replyId = replyId;

    // Register the watchdog slot BEFORE enqueueing. We always use 'server'
    // as the slot target because the server companion is what actually
    // POSTs /test-session/eval-result back to us (even for client-target
    // evals — see forwardTo dispatch in the server companion template).
    const replyPromise = this.bridge.registerEvalReply(replyId, 'server', tMs);

    const queued = this.bridge.enqueueTestCommand(
      {
        cmd: 'eval',
        args: evalArgs,
      },
      'server'
    );
    if (!queued) {
      // Bridge couldn't accept (session ended between status check and
      // enqueue, or invalid target). The watchdog will eventually trigger
      // a companion_error reply, but we'd rather not wait a full grace
      // window — return immediately.
      return fail(
        'companion_error',
        'Failed to enqueue eval command on the bridge (session may have just ended). Re-check play_solo state.'
      );
    }

    // Await the reply (will always resolve — watchdog guarantees it).
    const startedAt = Date.now();
    const reply = await replyPromise;
    const totalDurationMs = Date.now() - startedAt;

    // ---- Map the reply into the canonical Result shape ----------------
    const baseResult: Record<string, any> = {
      success: !!reply.ok,
      target,
      timeoutMs: tMs,
      durationMs: typeof reply.durationMs === 'number' ? reply.durationMs : totalDurationMs,
    };
    if (resolvedClientName) baseResult.player = { name: resolvedClientName, userId: resolvedClientUserId };

    if (reply.ok) {
      baseResult.values = reply.values ?? [];
      if (reply.logs && reply.logs.length > 0) baseResult.logs = reply.logs;
    } else {
      baseResult.error = reply.errorType ?? 'companion_error';
      baseResult.message = reply.error ?? 'Unknown eval failure.';
      if (reply.traceback) baseResult.traceback = reply.traceback;
      if (reply.logs && reply.logs.length > 0) baseResult.logs = reply.logs;
    }

    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(baseResult, null, 2),
        },
      ],
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

  /**
   * render_gui - Render a 2D GUI (ScreenGui / GuiObject) to a PNG image.
   *
   * ViewportFrame is 3D-only, so GUIs are captured plugin-side by cloning the
   * target's real ScreenGui into CoreGui (faithful placement), taking a
   * full-screen CaptureService screenshot, then cropping. region "element"
   * (default) crops tight to the element's rect; "screen" returns the whole
   * viewport so on-screen placement can be verified. Here we just convert the
   * returned RGBA to PNG, mirroring renderObjectView.
   */
  async renderGui(
    instancePath: string,
    options?: {
      region?: 'element' | 'screen';
      maxWidth?: number;
      maxHeight?: number;
    }
  ) {
    if (!instancePath) {
      throw new Error('Instance path is required for render_gui');
    }

    const response = await this.client.request('/api/render-gui', {
      instancePath,
      region: options?.region || 'element',
      maxWidth: options?.maxWidth,
      maxHeight: options?.maxHeight,
    });

    const responseData = response as any;
    if (responseData.success && responseData.base64) {
      try {
        const rgbaBuffer = Buffer.from(responseData.base64, 'base64');
        const width = responseData.width;
        const height = responseData.height;

        const expectedSize = width * height * 4;
        if (rgbaBuffer.length !== expectedSize) {
          throw new Error(
            `Buffer size mismatch: got ${rgbaBuffer.length}, expected ${expectedSize}`
          );
        }

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
                  guiInfo: responseData.guiInfo,
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
    // Plumb the docs SHA through so hybrid mode can locate / build the
    // matching semantic index. Without this, hybrid mode degrades to
    // pure keyword (semanticUsed=false in the response).
    const summary = await searchDocs(ensured.cacheDir, query, options, {
      docsSha: ensured.meta.sha,
    });
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