import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user_profile.dart';
import '../services/user_state_service.dart';
import 'main_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _onProfileTap(BuildContext context, UserProfile profile) {
    if (profile.hasPin) {
      _showPinDialog(context, profile);
    } else {
      _selectProfile(context, profile);
    }
  }

  void _selectProfile(BuildContext context, UserProfile profile) {
    Provider.of<UserStateService>(context, listen: false).setProfile(profile);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
  }

  void _showPinDialog(BuildContext context, UserProfile profile) {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(
            'Enter PIN for ${profile.name}',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: TextField(
            controller: pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
            decoration: const InputDecoration(
              hintText: '••••',
              hintStyle: TextStyle(color: Colors.white24),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFE50914))),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFE50914))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
              onPressed: () {
                if (profile.verifyPin(pinController.text)) {
                  Navigator.pop(ctx);
                  _selectProfile(context, profile);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Incorrect PIN. Try again.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Confirm', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showAddProfileDialog(BuildContext context) {
    final nameController = TextEditingController();
    final pinController = TextEditingController();
    bool isKids = false;
    String selectedAvatar = UserProfile.defaultAvatars.first;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: const Text('Add Profile', style: TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        labelStyle: TextStyle(color: Colors.white70),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFE50914))),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Kids Profile', style: TextStyle(color: Colors.white)),
                      value: isKids,
                      activeColor: const Color(0xFFE50914),
                      onChanged: (val) {
                        setModalState(() => isKids = val);
                      },
                    ),
                    TextField(
                      controller: pinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 4,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '4-Digit PIN (Optional)',
                        labelStyle: TextStyle(color: Colors.white70),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFE50914))),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isNotEmpty) {
                      final success = await Provider.of<UserStateService>(context, listen: false).addProfile(
                        name: name,
                        avatarUrl: isKids ? UserProfile.defaultAvatars[3] : selectedAvatar,
                        isKids: isKids,
                        pin: pinController.text.isNotEmpty ? pinController.text : null,
                      );
                      if (context.mounted) Navigator.pop(ctx);
                      if (!success && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Maximum 5 profiles allowed per account.')),
                        );
                      }
                    }
                  },
                  child: const Text('Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final userState = Provider.of<UserStateService>(context);
    final profiles = userState.profiles;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'FLIX',
          style: TextStyle(
            color: Color(0xFFE50914),
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "Who's Watching?",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 32),
              Wrap(
                spacing: 24,
                runSpacing: 28,
                alignment: WrapAlignment.center,
                children: [
                  ...profiles.map((p) => _ProfileTile(
                        profile: p,
                        onTap: () => _onProfileTap(context, p),
                      )),
                  if (profiles.length < 5)
                    GestureDetector(
                      onTap: () => _showAddProfileDialog(context),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white38, width: 2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(Icons.add, color: Colors.white70, size: 44),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Add Profile',
                            style: TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final UserProfile profile;
  final VoidCallback onTap;

  const _ProfileTile({required this.profile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  profile.avatarUrl,
                  width: 100,
                  height: 100,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 100,
                    height: 100,
                    color: profile.isKids ? Colors.amber[700] : const Color(0xFFE50914),
                    child: Center(
                      child: Text(
                        profile.name.isNotEmpty ? profile.name[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ),
              if (profile.hasPin)
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock, color: Colors.white, size: 14),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            profile.name,
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
