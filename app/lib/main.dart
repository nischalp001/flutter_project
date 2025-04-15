import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Get available cameras
  final cameras = await availableCameras();
  final firstCamera = cameras.first;
  
  runApp(
    MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: KiranaCartApp(camera: firstCamera),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class KiranaCartApp extends StatefulWidget {
  final CameraDescription camera;

  const KiranaCartApp({
    Key? key,
    required this.camera,
  }) : super(key: key);

  @override
  _KiranaCartAppState createState() => _KiranaCartAppState();
}

class DetectedItem {
  final String itemClass;
  final double confidence;
  final Rect boundingBox;
  
  DetectedItem({
    required this.itemClass,
    required this.confidence,
    required this.boundingBox,
  });
}

class _KiranaCartAppState extends State<KiranaCartApp> with WidgetsBindingObserver {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  bool _isDetecting = false;
  bool _checkoutClicked = false;
  String _status = "Initializing...";
  int _fps = 0;
  
  // For FPS calculation
  int _frameCount = 0;
  int _totalFrames = 0;
  DateTime _lastFpsUpdate = DateTime.now();
  
  // Detection results
  Map<String, int> _detectedItems = {};
  List<DetectedItem> _currentDetectedObjects = [];
  Timer? _detectionTimer;
  List<Map<String, dynamic>> _detectionHistory = [];
  
  // Constants
  final int _historyLength = 10;
  final int _minDetectionFrames = 3;
  
  // Server configuration
  final String _serverUrl = "http://192.168.10.117:3000/detect";
  
  // Product configurations
  final Map<String, Color> _productColors = {
    "Wai Wai": Colors.amber,
    "Ariel": Colors.green,
    "Coke": Colors.red,
    "Dettol": Colors.blue,
  };
  
  final Map<String, double> _itemPrices = {
    "Coke": 100,
    "Dettol": 25,
    "Wai Wai": 20,
    "Ariel": 175,
  };
  
  // Camera preview size for bounding box scaling
  Size _previewSize = Size(0, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize the camera
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    _initializeControllerFuture = _controller.initialize().then((_) {
      if (!mounted) return;
      
      // Store the preview size for bounding box calculations
      _previewSize = Size(
        _controller.value.previewSize!.height,
        _controller.value.previewSize!.width,
      );
      
      setState(() {
        _status = "Camera Ready";
      });
      
      // Start periodic detection
      _startDetection();
    }).catchError((error) {
      setState(() {
        _status = "Camera Error: $error";
      });
    });
  }

  void _startDetection() {
    // Run detection every 500ms
    _detectionTimer = Timer.periodic(Duration(milliseconds: 500), (timer) async {
      if (!_isDetecting && mounted && _controller.value.isInitialized) {
        await _detectFrame();
      }
    });
  }

  Future<void> _detectFrame() async {
    if (_isDetecting || _checkoutClicked) return;
    
    setState(() {
      _isDetecting = true;
    });
    
    try {
      // Take a picture
      final XFile image = await _controller.takePicture();
      
      // Send to server for detection
      await _sendImageForDetection(image.path);
      
      // Update FPS
      _frameCount++;
      _totalFrames++;
      final now = DateTime.now();
      if (now.difference(_lastFpsUpdate).inSeconds >= 1) {
        setState(() {
          _fps = _frameCount;
          _frameCount = 0;
          _lastFpsUpdate = now;
        });
      }
    } catch (e) {
      print("Detection error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isDetecting = false;
        });
      }
    }
  }

  Future<void> _sendImageForDetection(String imagePath) async {
    try {
      final file = File(imagePath);
      
      // Create multipart request
      var request = http.MultipartRequest('POST', Uri.parse(_serverUrl));
      
      // Add file to request
      request.files.add(await http.MultipartFile.fromPath(
        'image',
        file.path,
        contentType: MediaType('image', 'jpeg'),
      ));
      
      // Send the request
      var response = await request.send();
      
      if (response.statusCode == 200) {
        // Parse the response
        final responseData = await response.stream.bytesToString();
        final Map<String, dynamic> detectionResult = json.decode(responseData);
        
        if (detectionResult['status'] == 'success') {
          _updateDetections(detectionResult['data']['predictions']);
        }
      } else {
        print("Error: ${response.statusCode}");
      }
      
      // Delete the temporary file
      await file.delete();
      
    } catch (e) {
      print("Network error: $e");
    }
  }

  void _updateDetections(List<dynamic> predictions) {
    // Convert predictions to DetectedItem objects with bounding boxes
    List<DetectedItem> currentObjects = [];
    
    for (var prediction in predictions) {
      final itemClass = prediction['class'] as String;
      final confidence = (prediction['confidence'] as num).toDouble();
      
      // Extract bounding box coordinates
      final bbox = prediction['bbox'] as Map<String, dynamic>? ?? 
                  {'x': 0.0, 'y': 0.0, 'width': 0.0, 'height': 0.0};
      
      // Convert normalized coordinates (0-1) to pixel coordinates
      final x = (bbox['x'] as num).toDouble() * _previewSize.width;
      final y = (bbox['y'] as num).toDouble() * _previewSize.height;
      final width = (bbox['width'] as num).toDouble() * _previewSize.width;
      final height = (bbox['height'] as num).toDouble() * _previewSize.height;
      
      currentObjects.add(DetectedItem(
        itemClass: itemClass,
        confidence: confidence,
        boundingBox: Rect.fromLTWH(x, y, width, height),
      ));
    }
    
    // Count detections by class
    Map<String, int> currentDetections = {};
    
    for (var item in currentObjects) {
      final itemClass = item.itemClass;
      if (currentDetections.containsKey(itemClass)) {
        currentDetections[itemClass] = currentDetections[itemClass]! + 1;
      } else {
        currentDetections[itemClass] = 1;
      }
    }
    
    // Add to history
    _detectionHistory.add(currentDetections);
    if (_detectionHistory.length > _historyLength) {
      _detectionHistory.removeAt(0);
    }
    
    // Process history to get stable detections
    Map<String, int> itemCounts = {};
    
    for (var frameDets in _detectionHistory) {
      for (var item in frameDets.keys) {
        if (itemCounts.containsKey(item)) {
          itemCounts[item] = itemCounts[item]! + 1;
        } else {
          itemCounts[item] = 1;
        }
      }
    }
    
    // Find items that appear in enough frames
    Map<String, int> stableItems = {};
    
    for (var entry in itemCounts.entries) {
      final item = entry.key;
      final frames = entry.value;
      
      if (frames >= _minDetectionFrames) {
        Map<int, int> counts = {};
        
        for (var frameDets in _detectionHistory) {
          if (frameDets.containsKey(item)) {
            final quantity = frameDets[item]!;
            counts[quantity] = (counts[quantity] ?? 0) + 1;
          }
        }
        
        int maxCount = 0;
        int mostCommonQuantity = 0;
        
        counts.forEach((quantity, count) {
          if (count > maxCount) {
            maxCount = count;
            mostCommonQuantity = quantity;
          }
        });
        
        stableItems[item] = mostCommonQuantity;
      }
    }
    
    setState(() {
      _detectedItems = stableItems;
      _currentDetectedObjects = currentObjects;
      _status = stableItems.isNotEmpty ? "Products Detected" : "No Products Detected";
    });
  }

  void _checkout() {
    if (_detectedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No items detected in cart!'))
      );
      return;
    }
    
    setState(() {
      _checkoutClicked = true;
      _status = "Processing Checkout...";
    });
    
    // Calculate total
    double total = 0;
    _detectedItems.forEach((item, count) {
      total += (_itemPrices[item] ?? 0) * count;
    });
    
    // Show checkout completion after delay
    Future.delayed(Duration(seconds: 2), () {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('Checkout Complete'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._detectedItems.entries.map((entry) {
                final itemName = entry.key;
                final quantity = entry.value;
                final itemPrice = _itemPrices[itemName] ?? 0;
                final totalItemPrice = itemPrice * quantity;
                
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('$itemName × $quantity'),
                      Text('Rs. ${totalItemPrice.toStringAsFixed(2)}'),
                    ],
                  ),
                );
              }).toList(),
              Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Total:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('Rs. ${total.toStringAsFixed(2)}', 
                       style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              child: Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
                // Reset
                setState(() {
                  _checkoutClicked = false;
                  _detectedItems = {};
                  _currentDetectedObjects = [];
                  _status = "Ready for Next Customer";
                });
              },
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detectionTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.isInitialized) return;
    
    if (state == AppLifecycleState.inactive) {
      _controller.dispose();
      _detectionTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  void _initCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    
    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        _previewSize = Size(
          _controller.value.previewSize!.height,
          _controller.value.previewSize!.width,
        );
        setState(() {});
        _startDetection();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return _buildMainUI();
          } else {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text("Initializing camera...", style: TextStyle(fontSize: 18)),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildMainUI() {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                // Camera preview
                Container(
                  width: double.infinity,
                  child: CameraPreview(_controller),
                ),
                
                // Bounding boxes overlay
                ..._drawBoundingBoxes(),
                
                // Status indicator
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _status.contains("Error") 
                          ? Colors.red.withOpacity(0.7)
                          : Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      _status,
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                
                // FPS counter
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "FPS: $_fps",
                          style: TextStyle(color: Colors.white),
                        ),
                        Text(
                          "Total frames: $_totalFrames",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                
                // Instructions
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.8,
                      padding: EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text(
                            "Point camera at products to detect them",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            "Detected items will appear in the cart below",
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Cart section
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.white,
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    color: Colors.blue,
                    width: double.infinity,
                    child: Text(
                      "Your Shopping Cart",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  
                  // Cart items
                  Expanded(
                    child: _detectedItems.isEmpty
                      ? Center(
                          child: Text(
                            "No items detected",
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _detectedItems.length + 1, // +1 for total
                          itemBuilder: (context, index) {
                            if (index < _detectedItems.length) {
                              final item = _detectedItems.keys.elementAt(index);
                              final count = _detectedItems[item] ?? 0;
                              final unitPrice = _itemPrices[item] ?? 0;
                              final totalPrice = unitPrice * count;
                              final color = _productColors[item] ?? Colors.blue;
                              
                              return Container(
                                margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: color, width: 4),
                                  ),
                                  color: Colors.grey[100],
                                ),
                                child: ListTile(
                                  title: Text("$item × $count"),
                                  subtitle: Text(
                                    "Rs. ${unitPrice.toStringAsFixed(2)} each",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  trailing: Text(
                                    "Rs. ${totalPrice.toStringAsFixed(2)}",
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              );
                            } else {
                              // Total row
                              double total = 0;
                              _detectedItems.forEach((item, count) {
                                total += (_itemPrices[item] ?? 0) * count;
                              });
                              
                              return Container(
                                margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.grey[200],
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      "Total",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    Text(
                                      "Rs. ${total.toStringAsFixed(2)}",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Colors.blue[800],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                          },
                        ),
                  ),
                  
                  // Checkout button
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _checkoutClicked ? null : _checkout,
                        style: ElevatedButton.styleFrom(
                          padding: EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: _checkoutClicked
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text("Processing..."),
                              ],
                            )
                          : Text(
                              "CHECKOUT",
                              style: TextStyle(fontSize: 16),
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Draw bounding boxes for all detected objects
  List<Widget> _drawBoundingBoxes() {
    final List<Widget> boxes = [];
    
    // Get screen size for scaling
    final Size screenSize = MediaQuery.of(context).size;
    
    // Scaling factors
    final double scaleX = screenSize.width / _previewSize.width;
    final double scaleY = screenSize.height * 0.6 / _previewSize.height; // 60% of screen height for camera
    
    for (var obj in _currentDetectedObjects) {
      final color = _productColors[obj.itemClass] ?? Colors.blue;
      final price = _itemPrices[obj.itemClass] ?? 0.0;
      
      // Scale bounding box to screen size
      final Rect scaledRect = Rect.fromLTWH(
        obj.boundingBox.left * scaleX,
        obj.boundingBox.top * scaleY,
        obj.boundingBox.width * scaleX,
        obj.boundingBox.height * scaleY,
      );
      
      boxes.add(
        Positioned(
          left: scaledRect.left,
          top: scaledRect.top,
          child: Container(
            width: scaledRect.width,
            height: scaledRect.height,
            decoration: BoxDecoration(
              border: Border.all(
                color: color,
                width: 2.0,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
      
      // Add label with price
      boxes.add(
        Positioned(
          left: scaledRect.left,
          top: scaledRect.top - 20, // Position above the box
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.8),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              "${obj.itemClass} - Rs.${price.toStringAsFixed(0)}",
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
      
      // Add confidence score
      boxes.add(
        Positioned(
          right: screenSize.width - scaledRect.right,
          bottom: screenSize.height * 0.6 - scaledRect.bottom, // Adjusting for the box's position
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              "${(obj.confidence * 100).toStringAsFixed(0)}%",
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
              ),
            ),
          ),
        ),
      );
    }
    
    return boxes;
  }
}
