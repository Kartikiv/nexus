import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus/config/config.dart';
class ApiService {
  static final baseUrl = AppConfig.baseUrl;


  static Future<List<Map<String, String>>?> getRegisteredUsers(String userName, String token) async {
    final List<Map<String, String>> result = [];

    final url = Uri.parse('$baseUrl/getRegisteredUsers');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'userName': userName}),
      );

      if (response.statusCode == 200) {
  final data = jsonDecode(response.body);
  if (data != null &&
  data['firstName'] != null &&
  data['lastName'] != null &&
  data['userName'] != null) {
  result.add({
  'firstName': data['firstName'],
  'lastName': data['lastName'],
  'userName': data['userName'],
  });
  }

      return result;
      }




  else {

        return null;
      }
    } catch (e) {

      return null;
    }
  }

  /// Logs in the user and returns a map with username and token if successful.
  static Future<Map<String, dynamic>?> login(String username, String password) async {
    print(username);
    print(password);
    final response = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'Content-Type': 'application/json'},

      body: jsonEncode({'userName': username, 'password': password}),
    );
    print(response.body);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return {
        'username': data['username'],
        'token': data['token'],
      };
    }
    return null;
  }

  /// Registers a new user.
  static Future<bool> register(String username, String password, String firstNane, String LastName , String Email, String Phone) async {
    final response = await http.post(
      Uri.parse('$baseUrl/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userName': username,
        'password': password,
        'firstName': firstNane,
        'lastName': LastName,
        'email': Email,
        'phone': Phone,
        'role': 'USER'


      }, ),
    );
    print(response.body);
    return response.statusCode == 201;
  }

  /// Stores token and username in shared preferences.
  static Future<void> saveAuthData(String token, String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('username', username);
  }

  /// Returns the stored auth token.
  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  /// Returns the stored username.
  static Future<Map<String, dynamic>?> getUser(String username, String token) async {
    final url = Uri.parse('$baseUrl/users/$username');

    try {
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print('Failed to fetch user: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Error fetching user: $e');
      return null;
    }
  }


  /// Clears token and username from shared preferences (for logout).
  static Future<void> clearAuthData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
  }

  /// Example: A protected GET request
  static Future<http.Response> fetchProtectedData() async {
    final token = await getToken();
    return await http.get(
      Uri.parse('$baseUrl/protected'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );
  }
}
