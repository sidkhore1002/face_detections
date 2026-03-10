import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'http_override.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  HttpOverrides.global = MyHttpOverrides();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FaceRotationPage(),
    );
  }
}

class FaceRotationPage extends StatefulWidget {
  const FaceRotationPage({super.key});
  @override
  State<FaceRotationPage> createState() => _FaceRotationPageState();
}

class _FaceRotationPageState extends State<FaceRotationPage> {
  CameraController? _cameraController;
  bool _isDetecting = false;
  bool _isBusy = false;
  bool _showCaptureButton = false;
  bool _showStopButton = false;
  String _status = "Press Start";
  TextEditingController _ipController = TextEditingController();
  bool showLoader = false;

  bool _eyesClosed = false;
  bool _blinkDetected = false;

  FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableClassification: true, // REQUIRED for eye blink
      enableTracking: false,
    ),
  );

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras[0],
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Camera init error: $e");
      if (mounted) setState(() => _status = "Camera Error");
    }
  }

  void startDetection() {
    if (!isValidIpWithPort(_ipController.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Enter valid IP"),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
        ),
      );
      return;
    }

    if (_isDetecting || _cameraController == null) return;

    setState(() {
      _isBusy = false;
      _isDetecting = true;
      _showCaptureButton = false;
      _showStopButton = true;
      _eyesClosed = false;
      _blinkDetected = false;      
      _status = "Align face in center";
    });  
    _initFaceDetector();
    if (mounted) setState(() {});
    _cameraController!.startImageStream(_processImage);
  }

  Future<void> stopDetection() async {
    if (!_isDetecting || _cameraController == null) return;
    setState(() {
      showLoader = true;
    });
    try {
      await _cameraController!.stopImageStream();
      await _faceDetector.close();
    } catch (e) {
      setState(() {
        showLoader = false;
      });
    }
    setState(() {
      showLoader = false;
      _isDetecting = false;
      _showCaptureButton = false;
      _showStopButton = false;
      _status = "Press Start";
    });
  }

  // NEW: Capture and send image when blink is detected
  Future<void> _captureAndSendOnBlink(CameraImage image, Face face) async {
    if (_cameraController == null || showLoader) return;

    setState(() {
      showLoader = true;
      _status = "Processing blink...";
    });

    try {
      // Stop image stream first
      await _cameraController!.stopImageStream();
      await _faceDetector.close();

      // Convert YUV image to PNG file
      final processedFile = await _convertCameraImageToPng(image, face);

      if (processedFile != null) {
        // Validate face is centered
        if (await _validateCenterFace(processedFile)) {
          await sendFormDataImageToBE(processedFile);
          // ScaffoldMessenger.of(context).showSnackBar(
          //   SnackBar(
          //     content: Text("Welcome ssss...."),
          //     backgroundColor: Colors.green,
          //     behavior: SnackBarBehavior.floating,
          //     margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
          //   ),
          // );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Face not centered! Please align properly"),
              backgroundColor: Colors.orange,
            ),
          );
        }

        // Delete temp file
        await processedFile.delete();
      }
    } catch (e) {
      debugPrint("Blink capture error: $e");
    } finally {
      // Reset state
      setState(() {
        showLoader = false;
        _isDetecting = false;
        _showCaptureButton = false;
        _showStopButton = false;
        _status = "Press Start";
        _eyesClosed = false;
        _blinkDetected = false;
      });

      // Restart camera for next use
      _initFaceDetector();
    }
  }

  // NEW: Convert CameraImage (YUV) to PNG file
  Future<File?> _convertCameraImageToPng(CameraImage image, Face face) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final processedFile =
          File(path.join(tempDir.path, 'blink_face_$timestamp.png'));

      // Convert YUV to RGB using image package
      // final imageRGB = _yuv420ToImage(image);

      // Fix rotation
      final imageRGBraw = _yuv420ToImage(image);
      img.Image imageRGB = img.copyRotate(
        imageRGBraw,
        angle: _cameraController!.description.sensorOrientation,
      );

      // crop face 
      // Face bounding box
      final rect = face.boundingBox;

      int x = rect.left.toInt();
      int y = rect.top.toInt();
      int w = rect.width.toInt();
      int h = rect.height.toInt();

      // Add padding (better recognition)
      x = (x - w * 0.2).toInt();
      y = (y - h * 0.3).toInt();
      w = (w * 1.4).toInt();
      h = (h * 1.6).toInt();

      // Clamp to image bounds
      x = x.clamp(0, imageRGB.width - 1);
      y = y.clamp(0, imageRGB.height - 1);

      if (x + w > imageRGB.width) {
        w = imageRGB.width - x;
      }
      if (y + h > imageRGB.height) {
        h = imageRGB.height - y;
      }
      // Crop face
      final croppedFace = img.copyCrop(
        imageRGB,
        x: x,
        y: y,
        width: w,
        height: h,
      );

      // final pngBytes = img.encodePng(imageRGB);
      final pngBytes = img.encodePng(croppedFace);

      await processedFile.writeAsBytes(pngBytes);
      debugPrint("✅ Blink image saved: ${processedFile.path}");

      debugPrint("✅ Cropped face saved: ${processedFile.path}");

      // save file to external storage
      final permission = await Permission.storage.status;
      if (!permission.isGranted) {
        final result = await Permission.storage.request();
        if (!result.isGranted) {
          debugPrint("❌ Permission denied for Downloads");
        }
      }
      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      final downloadsFileName = 'FaceBlink_$timestamp.png';
      final downloadsFile =
          File(path.join(downloadsDir.path, downloadsFileName));

      await downloadsFile.writeAsBytes(pngBytes);
      debugPrint("✅ ✅ DOWNLOADS SAVED: ${downloadsFile.path}");

      return processedFile;
    } catch (e) {
      debugPrint("Image conversion error: $e");
      return null;
    }
  }

  Future<bool> _validateCenterFace(File imageFile) async {
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) return false;

      final face = faces.first;
      final angleY = face.headEulerAngleY ?? 0;

      // Check if face is centered (±15 degrees tolerance)
      return angleY.abs() <= 15;
    } catch (e) {
      debugPrint("Validation error: $e");
      return false;
    }
  }

  void _initFaceDetector() {
    FaceDetector _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableClassification: true, // REQUIRED for eye blink
        enableTracking: false,
      ),
    );
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isBusy || !_isDetecting || image.planes.length != 3) return;
    _isBusy = true;

    try {
      final inputImage = _convertYUV420Image(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        if (mounted) setState(() => _status = "No face detected");
        _isBusy = false;
        return;
      }

      final face = faces.first;
      final angleY = face.headEulerAngleY ?? 0;

      debugPrint("AngleY: $angleY");

      // Check if face is centered
      if (angleY.abs() <= 15) {
        final double? leftEye = face.leftEyeOpenProbability;
        final double? rightEye = face.rightEyeOpenProbability;

        if (leftEye == null || rightEye == null) {
          _isBusy = false;
          return;
        }

        debugPrint("Eyes: L=$leftEye R=$rightEye");

        if (mounted) {
          setState(() {
            _status = "Please blink your eyes";
          });
        }

        // Step 1: detect closed eyes
        if (leftEye < 0.3 && rightEye < 0.3) {
          _eyesClosed = true;
        }

        // Step 2: open eyes after closed = BLINK DETECTED ✅
        if (_eyesClosed && leftEye > 0.7 && rightEye > 0.7) {
          _blinkDetected = true;
          _eyesClosed = false;

          if (mounted) {
            setState(() {
              _status = "Blink detected! Capturing...";
            });
          }

          // CAPTURE AND SEND IMAGE AUTOMATICALLY
          await _captureAndSendOnBlink(image, face);
          return; // Exit processing after blink
        }
      } else {
        if (mounted) {
          setState(() {
            _status = "Align face in center (${angleY.toStringAsFixed(1)}°)";
          });
        }
      }
    } catch (e) {
      debugPrint("MLKit error: $e");
    }
    _isBusy = false;
  }

  bool isValidIpWithPort(String input) {
    final regex = RegExp(
      r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
      r'(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d):'
      r'(6553[0-5]|655[0-2]\d|65[0-4]\d{2}|6[0-4]\d{3}|[1-5]\d{4}|[1-9]\d{0,3})$',
    );
    return regex.hasMatch(input);
  }

  Future<void> sendFormDataImageToBE(File imageFile) async {
    try {
      final uri =
          Uri.parse("https://${_ipController.text}/query-face-from-image");
      var request = http.MultipartRequest('POST', uri);

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          imageFile.path,
          contentType: MediaType('image', 'png'),
        ),
      );

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      debugPrint("Response: $responseBody");

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Welcome ${data['data']['user_name']}"),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
            ),
          );
        }
      } else if (response.statusCode == 404) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Employee record not found"),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Server error: ${response.statusCode}"),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Upload error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Network error: $e"),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
          ),
        );
      }
    }
  }

  img.Image _yuv420ToImage(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;
    final img.Image imageRGB = img.Image(width: width, height: height);

    final Plane yPlane = cameraImage.planes[0];
    final Plane uPlane = cameraImage.planes[1];
    final Plane vPlane = cameraImage.planes[2];

    final int yBytesPerRow = yPlane.bytesPerRow;
    final int uvBytesPerRow = uPlane.bytesPerRow;
    final int? uvPixelStride = uPlane.bytesPerPixel;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int Y = yPlane.bytes[y * yBytesPerRow + x];
        final int uvRow = (y ~/ 2) * uvBytesPerRow;
        final int uvCol = (x ~/ 2) * (uvPixelStride ?? 1);
        final int uvIndex = uvRow + uvCol;

        final int U = uPlane.bytes[uvIndex];
        final int V = vPlane.bytes[uvIndex];

        int R = (Y + 1.402 * (V - 128)).round().clamp(0, 255);
        int G = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128))
            .round()
            .clamp(0, 255);
        int B = (Y + 1.772 * (U - 128)).round().clamp(0, 255);

        imageRGB.setPixelRgba(x, y, R, G, B, 255);
      }
    }
    return imageRGB;
  }

  InputImage _convertYUV420Image(CameraImage image) {
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    final yRowStride = image.planes[0].bytesPerRow;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel!;

    final WriteBuffer allBytes = WriteBuffer();

    for (int y = 0; y < image.height; y++) {
      allBytes.putUint8List(
          yPlane.sublist(y * yRowStride, y * yRowStride + image.width));
    }

    for (int y = 0; y < image.height ~/ 2; y++) {
      for (int x = 0; x < image.width ~/ 2; x++) {
        final uvIndex = y * uvRowStride + x * uvPixelStride!;
        allBytes.putUint8(vPlane[uvIndex]); // V
        allBytes.putUint8(uPlane[uvIndex]); // U
      }
    }

    final nv21Bytes = allBytes.done().buffer.asUint8List();
    final camera = _cameraController!.description;
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
            InputImageRotation.rotation0deg;

    return InputImage.fromBytes(
      bytes: nv21Bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final shouldExit = await _showExitDialog();

        if (shouldExit) {
          await stopDetection(); // stop camera safely
          // SystemNavigator.pop();        
          exit(0);
        }
      },      
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(title: const Text("Face Blink Detection")),
        body: Stack(
          children: [
            Column(
              children: [
                // IP Input Field
                Container(
                  padding: const EdgeInsets.all(20),
                  child: TextField(
                    controller: _ipController,
                    decoration: InputDecoration(
                      hintStyle: TextStyle(color: Colors.grey),
                      hintText: "192.168.1.5:42786",
                      labelText: "Server IP:Port",
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: CameraPreview(controller),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        _status,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          if (!_showStopButton)
                            ElevatedButton.icon(
                              onPressed: _isDetecting ? null : startDetection,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text("Start"),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 12),
                              ),
                            ),
                          if (_showStopButton)
                            ElevatedButton.icon(
                              onPressed: stopDetection,
                              icon: const Icon(Icons.stop),
                              label: const Text("Stop"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (showLoader)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                  child: Container(
                    color: Colors.black.withOpacity(0.4),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          "Processing...",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> _showExitDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Exit"),
          content: const Text("Are you sure you want to exit?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Exit"),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}
