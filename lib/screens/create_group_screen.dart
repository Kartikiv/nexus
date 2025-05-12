import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:http/http.dart' as http;
import 'package:nexus/config/config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../service/api_service.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  final String username;
  final String jwt;

  const CreateGroupScreen({super.key, required this.username, required this.jwt});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  List<Contact> contacts = [];
  List<String> selectedUsers = [];
  final List<Map<String, String>> recentChats = [];
  final List<Map<String, dynamic>> groups = [];
  bool loading = true;
  Timer? _contactLoadTimer;
  bool _isLoadingContacts = false;
  final TextEditingController _groupNameController = TextEditingController();
  final String backendBaseUrl = 'http://YOUR_BACKEND_HOST:PORT/api/groups';

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts({bool showLoading = true}) async {
    if (_isLoadingContacts) return;
    _isLoadingContacts = true;
    if (showLoading) setState(() => loading = true);

    try {
      final granted = await FlutterContacts.requestPermission();
      if (!granted) {
        setState(() => loading = false);
        _isLoadingContacts = false;
        return;
      }

      final all = await FlutterContacts.getContacts(withProperties: true);
      final valid = all.where((c) => c.phones.isNotEmpty && c.phones.first.number.trim().isNotEmpty).toList();

      final prefs = await SharedPreferences.getInstance();
      final jwt = prefs.getString('auth_token');
      if (jwt == null) {
        setState(() => loading = false);
        _isLoadingContacts = false;
        return;
      }

      final numbers = valid.map((c) => c.phones.first.number.replaceAll(RegExp(r'\D'), '')).toList();
      final matched = await ApiService.postRegisteredUsers(numbers, jwt);
      final matchedSet = matched?.toSet() ?? {};

      final filtered = valid.where((c) {
        final number = c.phones.first.number.replaceAll(RegExp(r'\D'), '');
        return matchedSet.contains(number);
      }).toList();

      if (_contactsChanged(contacts, filtered)) {
        setState(() {
          contacts = filtered;
          loading = false;
        });
      } else if (showLoading) {
        setState(() => loading = false);
      }
    } catch (e) {
      print("Error loading contacts: $e");
      if (showLoading) setState(() => loading = false);
    } finally {
      _isLoadingContacts = false;
    }
  }

  bool _contactsChanged(List<Contact> oldContacts, List<Contact> newContacts) {
    if (oldContacts.length != newContacts.length) return true;
    final oldNumbers = oldContacts.map((c) => c.phones.first.number.replaceAll(RegExp(r'\D'), '')).toSet();
    final newNumbers = newContacts.map((c) => c.phones.first.number.replaceAll(RegExp(r'\D'), '')).toSet();
    return !oldNumbers.containsAll(newNumbers) || !newNumbers.containsAll(oldNumbers);
  }
  String _generateGroupId(List<String> usernames) {
    usernames.sort();
    final input = usernames.join(',');
    return sha256.convert(utf8.encode(input)).toString();
  }

  Future<void> _createGroup() async {

    if (_groupNameController.text.trim().isEmpty || selectedUsers.isEmpty) return;

    final members = [widget.username, ...selectedUsers];
    final groupId = _generateGroupId(members);
    final groupName = _groupNameController.text.trim();

    final body = jsonEncode({
      'groupId': groupId,
      'groupName': groupName,
      'members': members,
    });
     print(body);
    final response = await http.post(
      Uri.parse('http://138.2.224.56:8888/messaging-server/api/groups/create'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${widget.jwt}'
      },
      body: body,
    );
    print(response.body);
    if (response.statusCode == 200 || response.statusCode == 400) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChatScreen(
              groupId: groupId,
              groupName: groupName,
              username: widget.username,
              jwt: widget.jwt,
            ),
          ),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to create group: ${response.body}")),
      );
    }
  }

  Widget _buildContactTile(Contact contact) {
    final phone = contact.phones.first.number.replaceAll(RegExp(r'\D'), '');
    final isSelected = selectedUsers.contains(phone);

    return ListTile(
      title: Text(contact.displayName),
      subtitle: Text(phone),
      trailing: Checkbox(
        value: isSelected,
        onChanged: (_) {
          setState(() {
            if (isSelected) {
              selectedUsers.remove(phone);
            } else {
              selectedUsers.add(phone);
            }
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Create Group")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _groupNameController,
              decoration: const InputDecoration(
                labelText: "Group Name",
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: contacts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
              itemCount: contacts.length,
              itemBuilder: (_, i) => _buildContactTile(contacts[i]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton(
              onPressed: _createGroup,
              child: const Text("Create and Open Group Chat"),
            ),
          )
        ],
      ),
    );
  }
}
