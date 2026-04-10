import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart'; // for FaceRotationPage

class MpinScreen extends StatefulWidget {
  const MpinScreen({super.key});

  @override
  State<MpinScreen> createState() => _MpinScreenState();
}

class _MpinScreenState extends State<MpinScreen> {
  final TextEditingController _mpinController = TextEditingController();

  Future<void> loginWithMpin() async {
    final url = Uri.parse("http://192.168.1.104:4500/mplogin");

    // setState(() {
    //   showLoader = true;
    // });

    try {
      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "mpin": _mpinController.text.trim(),
        }),
      );

      final data = jsonDecode(response.body);

      // ✅ SUCCESS (200)
      if (response.statusCode == 200) {
        final String token = data['data']['accessToken'];
        print(data['data']);

        // 👉 Store token (optional)
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove("token"); // clear token
        await prefs.setString("token", token);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message'] ?? "Login successful"),
              backgroundColor: Colors.green,
            ),
          );
        }

        Future.delayed(const Duration(milliseconds: 500), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const FaceRotationPage(),
            ),
          );
        });
      }

      // 🔐 INVALID MPIN (401)
      else if (response.statusCode == 401) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message'] ?? "Invalid MPIN"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }

      // 🚨 SERVER ERROR (5xx)
      else if (response.statusCode >= 500) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Server error. Please try again later."),
              backgroundColor: Colors.red,
            ),
          );
        }
      }

      // ⚠️ OTHER ERRORS
      else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message'] ?? "Something went wrong"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      // 🌐 NETWORK ERROR
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Network error: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        // setState(() {
        //   showLoader = false;
        // });
      }
    }
  }

  @override
  void dispose() {
    _mpinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Enter MPIN")),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              "Enter 6-digit MPIN",
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _mpinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "******",
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: loginWithMpin,
              child: const Text("Login"),
            ),
          ],
        ),
      ),
    );
  }
}
