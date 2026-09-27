import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/mcp_tool.dart';
import 'phone_tools/choice_tool.dart';
import 'phone_tools/sticker_tool.dart';
import 'phone_tools/voice_tool.dart';
import 'phone_tools/camera_tool.dart';
import 'phone_tools/diary_tool.dart';
import 'phone_tools/alarm_tool.dart';
import 'phone_tools/calendar_read_tool.dart';
import 'phone_tools/recall_tool.dart';
import 'phone_tools/file_tool.dart';
import 'phone_tools/location_tool.dart';
import 'phone_tools/memory_tool.dart';
import 'phone_tools/music_tool.dart';
import 'phone_tools/sensors_tool.dart';
import 'phone_tools/search_tool.dart';
import 'phone_tools/self_note_tool.dart';
import 'phone_tools/avatar_tool.dart';
import 'phone_tools/glance_tool.dart';
import 'phone_tools/small_thing_tool.dart';
import 'tool_tiers.dart';
import 'phone_tools/weather_tool.dart';
import 'phone_tools/weread_tool.dart';

typedef ToolExecutor =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> args);

class McpServer {
  HttpServer? _server;
  bool _isRunning = false;
  final List<WebSocket> _clients = [];
  final Map<String, ToolExecutor> _tools = {};
  final List<ToolRegistration> _toolRegistrations = [];

  /// Events stream for the UI to listen to
  final StreamController<McpServerEvent> _eventController =
      StreamController<McpServerEvent>.broadcast();
  Stream<McpServerEvent> get events => _eventController.stream;

  bool get isRunning => _isRunning;
  int get clientCount => _clients.length;
  List<ToolRegistration> get registeredTools => _toolRegistrations;

  McpServer() {
    _registerBuiltinTools();
  }

  void _registerBuiltinTools() {
    _registerTool(VoiceTool.definition, VoiceTool.execute);
    _registerTool(StickerTool.definition, StickerTool.execute);
    _registerTool(ChoiceTool.definition, ChoiceTool.execute);
    _registerTool(CameraTool.definition, CameraTool.execute);
    _registerTool(GalleryTool.definition, GalleryTool.execute);
    _registerTool(FileTool.definition, FileTool.execute);
    _registerTool(WriteFileTool.definition, WriteFileTool.execute);
    _registerTool(ReadFileTool.definition, ReadFileTool.execute);
    _registerTool(ListFilesTool.definition, ListFilesTool.execute);
    _registerTool(ClipboardTool.definition, ClipboardTool.execute);
    _registerTool(LocationTool.definition, LocationTool.execute);
    _registerTool(SensorTool.definition, SensorTool.execute);
    _registerTool(SearchTool.definition, SearchTool.execute);
    _registerTool(NewsTool.definition, NewsTool.execute);
    _registerTool(WeatherTool.definition, WeatherTool.execute);
    _registerTool(DiaryTool.definition, DiaryTool.execute);
    _registerTool(RecallTool.definition, RecallTool.execute);
    _registerTool(SaveToCornerTool.definition, SaveToCornerTool.execute);
    // 记忆。原来是 remember/open_memory/update_memory/forget 四个，
    // 现在是一个带 action 的——合并的理由见 MemoryTools.definition 的注释。
    // 注册在 recall/save 旁边是有意的：这三个合起来才是完整的记忆——
    // 常驻的（memory）和按需翻的（recall_records/save_to_corner）。
    _registerTool(MemoryTools.definition, MemoryTools.execute);
    // 便签：不是记忆的一种，是「主动说话」的由头。
    // 记忆答的是「她是谁」，便签答的是「这件事还没完」——前者常驻，
    // 后者到点兑现完就没了。
    _registerTool(SelfNoteTool.definition, SelfNoteTool.execute);
    // 「一起听歌」。**不进常驻层**（见 tool_tiers.dart 的判据）：它是「被专门
    // 要求」的那种——用户说「下一首」，模型先用 find_tools 把它取出来。
    // 常驻的应该是「她随口一句就得接住」的，音乐不是。
    _registerTool(MusicTool.definition, MusicTool.execute);
    _registerTool(AvatarTool.definition, AvatarTool.execute);
    _registerTool(GlanceTool.definition, GlanceTool.execute);
    // 延迟层的入口。必须常驻——它要是也收起来，延迟层等于不存在。
    _registerTool(ToolFinder.definition, ToolFinder.execute);
    _registerTool(SmallThingTool.definition, SmallThingTool.execute);
    _registerTool(AlarmTool.definition, AlarmTool.execute);
    _registerTool(TimerTool.definition, TimerTool.execute);
    _registerTool(CalendarTool.definition, CalendarTool.execute);
    _registerTool(CalendarReadTool.definition, CalendarReadTool.execute);
    _registerTool(
      ListHighlightedBooksTool.definition,
      ListHighlightedBooksTool.execute,
    );
    _registerTool(
      GetBookHighlightsTool.definition,
      GetBookHighlightsTool.execute,
    );
  }

  void _registerTool(McpTool tool, ToolExecutor executor) {
    _tools[tool.name] = executor;
    _toolRegistrations.add(ToolRegistration(tool: tool, executor: executor));
  }

  /// Register a custom tool at runtime
  void registerTool(McpTool tool, ToolExecutor executor) {
    _registerTool(tool, executor);
  }

  Future<bool> start(int port) async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;
      _eventController.add(McpServerEvent('started', {'port': port}));

      _server!.listen((HttpRequest request) {
        if (request.uri.path == '/ws') {
          WebSocketTransformer.upgrade(request).then((ws) {
            _handleClient(ws);
          });
        } else {
          // HTTP endpoint for tool listing
          if (request.method == 'GET' && request.uri.path == '/tools') {
            request.response.headers.contentType = ContentType.json;
            final toolsJson =
                _toolRegistrations.map((r) => r.tool.toJson()).toList();
            request.response.write(jsonEncode(toolsJson));
            request.response.close();
          } else {
            request.response.statusCode = 404;
            request.response.write('Not Found');
            request.response.close();
          }
        }
      });

      return true;
    } catch (e) {
      _eventController.add(
        McpServerEvent('error', {'message': '启动 MCP Server 失败: $e'}),
      );
      return false;
    }
  }

  void _handleClient(WebSocket ws) {
    _clients.add(ws);
    _eventController.add(
      McpServerEvent('client_connected', {'total': _clients.length}),
    );

    ws.listen(
      (data) {
        _handleMessage(ws, data);
      },
      onDone: () {
        _clients.remove(ws);
        _eventController.add(
          McpServerEvent('client_disconnected', {'total': _clients.length}),
        );
      },
      onError: (e) {
        _clients.remove(ws);
      },
    );
  }

  void _handleMessage(WebSocket ws, dynamic data) {
    try {
      final request = McpRequest.fromJson(jsonDecode(data.toString()));
      _processRequest(ws, request);
    } catch (e) {
      _sendError(ws, null, -32700, 'Parse error: $e');
    }
  }

  void _processRequest(WebSocket ws, McpRequest request) {
    switch (request.method) {
      case 'initialize':
        _sendResult(ws, request.id, {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'phone-mcp-server', 'version': '1.0.0'},
        });
        break;

      case 'tools/list':
        final toolsJson =
            _toolRegistrations.map((r) => r.tool.toJson()).toList();
        _sendResult(ws, request.id, {'tools': toolsJson});
        break;

      case 'tools/call':
        _handleToolCall(ws, request);
        break;

      case 'notifications/initialized':
        // Ignore, just a notification
        break;

      default:
        _sendError(
          ws,
          request.id,
          -32601,
          'Method not found: ${request.method}',
        );
    }
  }

  void _handleToolCall(WebSocket ws, McpRequest request) {
    final params = request.params;
    if (params == null || !params.containsKey('name')) {
      _sendError(ws, request.id, -32602, 'Missing tool name');
      return;
    }

    final name = params['name'] as String;
    final args = params['arguments'] as Map<String, dynamic>? ?? {};

    final executor = _tools[name];
    if (executor == null) {
      _sendError(ws, request.id, -32602, 'Tool not found: $name');
      return;
    }

    _eventController.add(
      McpServerEvent('tool_call', {'name': name, 'args': args}),
    );

    executor(args)
        .then((result) {
          _sendResult(ws, request.id, result);
          _eventController.add(
            McpServerEvent('tool_result', {
              'name': name,
              'success': result['success'],
            }),
          );
        })
        .catchError((e) {
          _sendError(ws, request.id, -32603, 'Tool execution error: $e');
        });
  }

  void _sendResult(WebSocket ws, String? id, dynamic result) {
    final response = {'jsonrpc': '2.0', 'result': result, 'id': id};
    ws.add(jsonEncode(response));
  }

  void _sendError(WebSocket ws, String? id, int code, String message) {
    final response = {
      'jsonrpc': '2.0',
      'error': {'code': code, 'message': message},
      'id': id,
    };
    ws.add(jsonEncode(response));
  }

  Future<void> stop() async {
    for (final client in _clients) {
      await client.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    _eventController.add(McpServerEvent('stopped', {}));
  }

  void dispose() {
    stop();
    _eventController.close();
  }
}

class McpServerEvent {
  final String type;
  final Map<String, dynamic> data;

  const McpServerEvent(this.type, this.data);
}

class ToolRegistration {
  final McpTool tool;
  final ToolExecutor executor;

  const ToolRegistration({required this.tool, required this.executor});
}
