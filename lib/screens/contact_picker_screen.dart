import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

class ContactPickerScreen extends StatefulWidget {
  const ContactPickerScreen({super.key});

  @override
  State<ContactPickerScreen> createState() => _ContactPickerScreenState();
}

class _ContactPickerScreenState extends State<ContactPickerScreen> {
  List<Contact> contacts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final granted = await FlutterContacts.requestPermission();
    if (!granted) {
      setState(() => loading = false);
      return;
    }

    final allContacts = await FlutterContacts.getContacts(withProperties: true);
    final valid = allContacts.where((c) =>
    c.phones.isNotEmpty &&
        c.phones.first.number.trim().isNotEmpty).toList();

    setState(() {
      contacts = valid;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Select Contact")),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : contacts.isEmpty
          ? const Center(child: Text("No contacts with phone numbers"))
          : ListView.builder(
        itemCount: contacts.length,
        itemBuilder: (_, index) {
          final contact = contacts[index];
          final number = contact.phones.first.number.replaceAll(RegExp(r'\D'), '');

          return ListTile(
            title: Text(contact.displayName ?? number),
            subtitle: Text(number),
            onTap: () => Navigator.pop(context, number),
          );
        },
      ),
    );
  }
}
