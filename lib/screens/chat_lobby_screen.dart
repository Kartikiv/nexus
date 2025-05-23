import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../service/api_service.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';

class ChatLobbyScreen extends StatefulWidget {
  final String username;
  final String firstName;
  final String jwt;

  const ChatLobbyScreen({
    super.key,
    required this.username,
    required this.firstName,
    required this.jwt,
  });

  @override
  State<ChatLobbyScreen> createState() => _ChatLobbyScreenState();
}

class _ChatLobbyScreenState extends State<ChatLobbyScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Contact> contacts = [];
  final List<Map<String, String>> recentChats = [];
  final List<Map<String, dynamic>> groups = [];
  bool loading = true;
  Timer? _contactLoadTimer;
  bool _isLoadingContacts = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadRecentChats();
    _loadContacts();
    _loadGroups();
    _contactLoadTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isLoadingContacts) _loadContacts(showLoading: false);
    });
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    Navigator.of(context).pushReplacementNamed('/');
  }

  void saveRecentChats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'recent_chats_${widget.username}';
    final encoded = recentChats.map((chat) => jsonEncode(chat)).toList();
    await prefs.setStringList(key, encoded);
  }

  Future<void> _loadRecentChats() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'recent_chats_${widget.username}';
    final rawList = prefs.getStringList(key);
    setState(() {
      recentChats.clear();
      if (rawList != null) {
        recentChats.addAll(rawList.map((e) => Map<String, String>.from(jsonDecode(e))));
      }
      if (!recentChats.any((chat) => chat['number'] == 'bob')) {
        recentChats.add({'name': 'Bob the Bot', 'number': 'bob'});
      }
    });
  }

  Future<void> _loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('groups_${widget.username}') ?? [];
    setState(() {
      groups.clear();
      groups.addAll(raw.map((e) => jsonDecode(e) as Map<String, dynamic>));
    });
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

  void openChat(String name, String number) {
    if (number == 'bob') {
      Navigator.pushNamed(context, '/bob');
      return;
    }
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
          recipientName: name,
        ),
      ),
    ).then((_) => setState(() {}));
  }

  void openGroup(Map<String, dynamic> group) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(
          groupId: group['groupId'],
          groupName: group['groupName'],
          username: widget.username,
          jwt: widget.jwt,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _contactLoadTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildChatList() {
    if (recentChats.isEmpty) return const Center(child: Text("No recent chats"));
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
    return RefreshIndicator(
      onRefresh: () => _loadContacts(),
      child: ListView.builder(
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
      ),
    );
  }

  Widget _buildGroupList() {
    if (groups.isEmpty) return const Center(child: Text("No groups created"));
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (_, i) {
        final group = groups[i];
        return ListTile(
          title: Text(group['groupName'] ?? 'Unnamed Group'),
          subtitle: Text("${group['members']?.length ?? 0} members"),
          onTap: () => openGroup(group),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Welcome, ${widget.firstName}"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadContacts();
              _loadGroups();
            },
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.group_add),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CreateGroupScreen(
                  username: widget.username,
                  jwt: widget.jwt,
                ),
              ),
            ).then((_) => _loadGroups()),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          )
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "Chats"),
            Tab(text: "Contacts"),
            Tab(text: "Groups"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChatList(),
          _buildContactList(),
          _buildGroupList(),
        ],
      ),
    );
  }
}
