import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../service/api_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController firstNameController = TextEditingController();
  final TextEditingController lastNameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController phoneNumberController = TextEditingController();

  bool _isLoading = false;
  String? _error;

  Future<void> register() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final success = await ApiService.register(
        usernameController.text.trim(),
        passwordController.text.trim(),

        firstNameController.text.trim(),
        lastNameController.text.trim(),
        emailController.text.trim(),
        phoneNumberController.text.trim(),
      );

      setState(() => _isLoading = false);

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(" Registered successfully")),
        );
        Navigator.pop(context);
      } else {
        setState(() => _error = "Registration failed. Try a different username.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Register")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
              TextFormField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: "Username"),
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                validator: (value) => value!.isEmpty ? "Required" : null,

              ),
              TextFormField(
                controller: passwordController,
                decoration: const InputDecoration(labelText: "Password"),
                obscureText: true,
                validator: (value) => value!.isEmpty ? "Required" : null,
              ),
              TextFormField(
                controller: firstNameController,
                decoration: const InputDecoration(labelText: "First Name"),
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                validator: (value) => value!.isEmpty ? "Required" : null,

              ),
              TextFormField(
                controller: lastNameController,
                decoration: const InputDecoration(labelText: "Last Name"),
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                validator: (value) => value!.isEmpty ? "Required" : null,

              ),TextFormField(
                controller: emailController,
                decoration: const InputDecoration(labelText: "Email Id"),
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                validator: (value) => value!.isEmpty ? "Required" : null,

              ),
              TextFormField(
                controller: phoneNumberController,
                decoration: const InputDecoration(labelText: "Phone Number"),
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                textCapitalization: TextCapitalization.none,
                validator: (value) => value!.isEmpty ? "Required" : null,

              ),

              const SizedBox(height: 20),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                onPressed: register,
                child: const Text("Register"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Already have an account? Login"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
