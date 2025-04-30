import 'dart:convert';

import 'package:flutter/material.dart';
import '../service/api_service.dart';
import 'chat_screen.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatLobbyScreen extends StatefulWidget {
  final String username;
  const ChatLobbyScreen({super.key, required this.username});

  @override
  State<ChatLobbyScreen> createState() => _ChatLobbyScreenState();
}

class _ChatLobbyScreenState extends State<ChatLobbyScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Contact> contacts = [];
  final List<Map<String, String>> recentChats = []; // [ {name, number} ]
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadRecentChats();
    _loadContacts();
  }
  void saveRecentChats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'recent_chats_${widget.username}';
    final encoded = recentChats.map((chat) => jsonEncode(chat)).toList();
    await prefs.setStringList(key, encoded);
  }
  _loadRecentChats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'recent_chats_${widget.username}';
    final rawList = prefs.getStringList(key);
    if (rawList != null) {
      setState(() {
        recentChats.clear();
        recentChats.addAll(rawList.map((e) => Map<String, String>.from(jsonDecode(e))));
      });
    }
  }

  Future<void> _loadContacts() async {
    setState(() {
      loading = true;
    });

    final granted = await FlutterContacts.requestPermission();
    if (!granted) {
      setState(() {
        loading = false;
      });
      return;
    }

    final all = await FlutterContacts.getContacts(withProperties: true);
    final valid = all.where((c) =>
    c.phones.isNotEmpty &&
        c.phones.first.number.trim().isNotEmpty).toList();

    List<Contact> filtered = [];
    final prefs = await SharedPreferences.getInstance();
    final jwt = prefs.getString('auth_token');

    if (jwt == null) {
      setState(() {
        loading = false;
      });
      return;
    }

    for (final contact in valid) {
      final number = contact.phones.first.number.replaceAll(RegExp(r'\D'), '');
      final userData = await ApiService.getRegisteredUsers(number, jwt);
      print("Response for $number: $userData");
      if (userData != null) {
        filtered.add(contact);
      }
    }
    for (final c in filtered) {
      print("${c.displayName} - ${c.phones.first.number}");
    }
    setState(() {
      contacts = filtered;
      loading = false;
    });
  }


  void openChat(String name, String number) {
    if (!recentChats.any((c) => c['number'] == number)) {
      recentChats.add({'name': name, 'number': number});
      saveRecentChats();
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          username: widget.username,
          recipient: number,
        ),
      ),
    ).then((_) => setState(() {})); // Refresh on return
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildChatList() {
    if (recentChats.isEmpty) {
      return const Center(child: Text("No recent chats"));
    }
    return ListView.builder(
      itemCount: recentChats.length,
      itemBuilder: (_, index) {
        final chat = recentChats[index];
        return ListTile(
          title: Text(chat['name']!),
          subtitle: Text(chat['number']!),
          trailing: const Icon(Icons.chat),
          onTap: () => openChat(chat['name']!, chat['number']!),
        );
      },
    );
  }

  Widget _buildContactList() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (contacts.isEmpty) return const Center(child: Text("No contacts found"));

    return ListView.builder(
      itemCount: contacts.length,
      itemBuilder: (_, index) {
        final c = contacts[index];
        final number = c.phones.first.number.replaceAll(RegExp(r'\D'), '');
        final name = c.displayName ?? number;

        if (number == widget.username) return const SizedBox.shrink();

        return ListTile(
          title: Text(name),
          subtitle: Text(number),
          onTap: () => openChat(name, number),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Welcome, ${widget.username}"),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "Chats"),
            Tab(text: "Contacts"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChatList(),
          _buildContactList(),
        ],
      ),
    );
  }
}
