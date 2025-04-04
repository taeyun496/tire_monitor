import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'onboarding_screen.dart';

// 연결 상태 enum
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error
}

// 타이어 데이터 모델
class TireData {
  final String position;
  final double pressure;
  final double wear;

  TireData({
    required this.position,
    required this.pressure,
    required this.wear,
  });

  factory TireData.fromJson(Map<String, dynamic> json) {
    return TireData(
      position: json['position'] as String,
      pressure: (json['pressure'] as num).toDouble(),
      wear: (json['wear'] as num).toDouble(),
    );
  }
}

// 설정 관리 클래스
class TireMonitorSettings {
  static const String _serverIpKey = 'server_ip';
  static const String _pressureThresholdKey = 'pressure_threshold';
  static const String _wearThresholdKey = 'wear_threshold';
  static const String _updateIntervalKey = 'update_interval';

  static const String defaultServerIp = '192.168.0.100';
  static const double defaultPressureThreshold = 70.0;
  static const double defaultWearThreshold = 0.9;
  static const int defaultUpdateInterval = 30;

  final SharedPreferences _prefs;

  TireMonitorSettings._(this._prefs);

  static Future<TireMonitorSettings> create() async {
    final prefs = await SharedPreferences.getInstance();
    return TireMonitorSettings._(prefs);
  }

  String get serverIp => _prefs.getString(_serverIpKey) ?? defaultServerIp;
  double get pressureThreshold => _prefs.getDouble(_pressureThresholdKey) ?? defaultPressureThreshold;
  double get wearThreshold => _prefs.getDouble(_wearThresholdKey) ?? defaultWearThreshold;
  int get updateInterval => _prefs.getInt(_updateIntervalKey) ?? defaultUpdateInterval;

  Future<void> setServerIp(String value) => _prefs.setString(_serverIpKey, value);
  Future<void> setPressureThreshold(double value) => _prefs.setDouble(_pressureThresholdKey, value);
  Future<void> setWearThreshold(double value) => _prefs.setDouble(_wearThresholdKey, value);
  Future<void> setUpdateInterval(int value) => _prefs.setInt(_updateIntervalKey, value);
}

// WebSocket 서비스
class TireMonitorService {
  late final TireMonitorSettings _settings;
  WebSocketChannel? _channel;
  final _tireDataController = StreamController<Map<String, TireData>>.broadcast();
  final _connectionStatusController = StreamController<ConnectionStatus>.broadcast();
  final _lastUpdateTimeController = StreamController<DateTime>.broadcast();

  Stream<Map<String, TireData>> get tireDataStream => _tireDataController.stream;
  Stream<ConnectionStatus> get connectionStatusStream => _connectionStatusController.stream;
  Stream<DateTime> get lastUpdateTimeStream => _lastUpdateTimeController.stream;

  Future<void> initialize(TireMonitorSettings settings) async {
    _settings = settings;
    connect();
  }

  String get wsUrl => 'ws://${_settings.serverIp}:8080';

  void connect() {
    _updateConnectionStatus(ConnectionStatus.connecting);
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel!.stream.listen(
        (data) {
          _updateConnectionStatus(ConnectionStatus.connected);
          final Map<String, dynamic> jsonData = json.decode(data);
          final Map<String, TireData> tireData = {};
          
          jsonData.forEach((key, value) {
            tireData[key] = TireData.fromJson(value);
          });
          
          _tireDataController.add(tireData);
          _lastUpdateTimeController.add(DateTime.now());
        },
        onError: (error) {
          print('WebSocket error: $error');
          _updateConnectionStatus(ConnectionStatus.error);
          // 에러 발생 시 재연결 시도
          Future.delayed(const Duration(seconds: 5), connect);
        },
        onDone: () {
          print('WebSocket connection closed');
          _updateConnectionStatus(ConnectionStatus.disconnected);
          // 연결 종료 시 재연결 시도
          Future.delayed(const Duration(seconds: 5), connect);
        },
      );
    } catch (e) {
      print('Connection error: $e');
      _updateConnectionStatus(ConnectionStatus.error);
      // 연결 실패 시 재연결 시도
      Future.delayed(const Duration(seconds: 5), connect);
    }
  }

  void _updateConnectionStatus(ConnectionStatus status) {
    _connectionStatusController.add(status);
  }

  void dispose() {
    _channel?.sink.close();
    _tireDataController.close();
    _connectionStatusController.close();
    _lastUpdateTimeController.close();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final bool onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;
  
  runApp(MyApp(onboardingCompleted: onboardingCompleted));
}

class MyApp extends StatelessWidget {
  final bool onboardingCompleted;

  const MyApp({super.key, required this.onboardingCompleted});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bicycle Tire Monitor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      initialRoute: onboardingCompleted ? '/home' : '/onboarding',
      routes: {
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const TireMonitorPage(),
      },
    );
  }
}

class TireMonitorPage extends StatefulWidget {
  const TireMonitorPage({super.key});

  @override
  State<TireMonitorPage> createState() => _TireMonitorPageState();
}

class _TireMonitorPageState extends State<TireMonitorPage> {
  late final TireMonitorService _monitorService;
  late final TireMonitorSettings _settings;
  Map<String, TireData> tireData = {
    'Rear': TireData(position: 'Rear', pressure: 85.0, wear: 0.8),
  };
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DateTime? _lastUpdateTime;
  Timer? _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    _settings = await TireMonitorSettings.create();
    _monitorService = TireMonitorService();
    await _monitorService.initialize(_settings);
    
    _monitorService.tireDataStream.listen((data) {
      setState(() {
        tireData = data;
      });
    });
    _monitorService.connectionStatusStream.listen((status) {
      setState(() {
        _connectionStatus = status;
      });
    });
    _monitorService.lastUpdateTimeStream.listen((time) {
      setState(() {
        _lastUpdateTime = time;
      });
    });

    _updateCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _monitorService.dispose();
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  Color _getScoreColor(double score) {
    if (score >= 90) return Colors.green;
    if (score >= 70) return Colors.orange;
    return Colors.red;
  }

  String _getLastUpdateText() {
    if (_lastUpdateTime == null) return 'No data received';
    
    final difference = DateTime.now().difference(_lastUpdateTime!);
    if (difference.inSeconds < 60) {
      return 'Updated ${difference.inSeconds}s ago';
    } else if (difference.inMinutes < 60) {
      return 'Updated ${difference.inMinutes}m ago';
    } else {
      return 'Updated ${difference.inHours}h ago';
    }
  }

  bool _isDataStale() {
    if (_lastUpdateTime == null) return true;
    return DateTime.now().difference(_lastUpdateTime!) > const Duration(seconds: 30);
  }

  Widget _buildLastUpdateTime() {
    final isStale = _isDataStale();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isStale ? Colors.orange.withOpacity(0.1) : Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isStale ? Icons.warning_amber_rounded : Icons.update,
            color: isStale ? Colors.orange : Colors.green,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            _getLastUpdateText(),
            style: TextStyle(
              color: isStale ? Colors.orange : Colors.green,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (_connectionStatus) {
      case ConnectionStatus.connected:
        statusColor = Colors.green;
        statusText = 'Connected';
        statusIcon = Icons.wifi;
        break;
      case ConnectionStatus.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        statusIcon = Icons.sync;
        break;
      case ConnectionStatus.error:
        statusColor = Colors.red;
        statusText = 'Connection Error';
        statusIcon = Icons.error_outline;
        break;
      case ConnectionStatus.disconnected:
        statusColor = Colors.grey;
        statusText = 'Disconnected';
        statusIcon = Icons.wifi_off;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: TextStyle(color: statusColor),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tire Monitor'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          _buildLastUpdateTime(),
          const SizedBox(width: 8),
          _buildConnectionStatus(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(settings: _settings),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tire Status',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: tireData.entries.map((entry) {
                  return TireStatusCard(
                    position: entry.key,
                    pressure: entry.value.pressure,
                    wear: entry.value.wear,
                    getScoreColor: _getScoreColor,
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TireStatusCard extends StatelessWidget {
  final String position;
  final double pressure;
  final double wear;
  final Color Function(double) getScoreColor;

  const TireStatusCard({
    super.key,
    required this.position,
    required this.pressure,
    required this.wear,
    required this.getScoreColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Bicycle Tire',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildScoreIndicator('Pressure Score', pressure),
            const SizedBox(height: 8),
            _buildStatusRow('Wear', '${(wear * 100).toStringAsFixed(1)}%'),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreIndicator(String label, double score) {
    final color = getScoreColor(score);
    return Column(
      children: [
        Text(label),
        const SizedBox(height: 4),
        Text(
          score.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: score / 100,
          backgroundColor: Colors.grey[200],
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }

  Widget _buildStatusRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final TireMonitorSettings settings;

  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _serverIpController;
  late double _pressureThreshold;
  late double _wearThreshold;
  late int _updateInterval;

  @override
  void initState() {
    super.initState();
    _serverIpController = TextEditingController(text: widget.settings.serverIp);
    _pressureThreshold = widget.settings.pressureThreshold;
    _wearThreshold = widget.settings.wearThreshold;
    _updateInterval = widget.settings.updateInterval;
  }

  @override
  void dispose() {
    _serverIpController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    await widget.settings.setServerIp(_serverIpController.text);
    await widget.settings.setPressureThreshold(_pressureThreshold);
    await widget.settings.setWearThreshold(_wearThreshold);
    await widget.settings.setUpdateInterval(_updateInterval);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          TextField(
            controller: _serverIpController,
            decoration: const InputDecoration(
              labelText: 'Server IP Address',
              hintText: 'Enter server IP address',
            ),
          ),
          const SizedBox(height: 16),
          Text('Pressure Threshold: ${_pressureThreshold.toStringAsFixed(1)}'),
          Slider(
            value: _pressureThreshold,
            min: 0,
            max: 100,
            divisions: 20,
            label: _pressureThreshold.toStringAsFixed(1),
            onChanged: (value) {
              setState(() {
                _pressureThreshold = value;
              });
            },
          ),
          const SizedBox(height: 16),
          Text('Wear Threshold: ${(_wearThreshold * 100).toStringAsFixed(1)}%'),
          Slider(
            value: _wearThreshold,
            min: 0,
            max: 1,
            divisions: 10,
            label: '${(_wearThreshold * 100).toStringAsFixed(1)}%',
            onChanged: (value) {
              setState(() {
                _wearThreshold = value;
              });
            },
          ),
          const SizedBox(height: 16),
          Text('Update Interval: ${_updateInterval}s'),
          Slider(
            value: _updateInterval.toDouble(),
            min: 5,
            max: 60,
            divisions: 11,
            label: '${_updateInterval}s',
            onChanged: (value) {
              setState(() {
                _updateInterval = value.round();
              });
            },
          ),
        ],
      ),
    );
  }
}
