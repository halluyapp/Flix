import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user_profile.dart';
import '../services/user_state_service.dart';
import 'main_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = UserProfile.defaultProfiles;
    final userState = Provider.of<UserStateService>(context, listen: false);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Who's Watching?',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: GridView.builder(
            shrinkWrap: true,
            itemCount: profiles.length + 1,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 24,
              mainAxisSpacing: 28,
              childAspectRatio: 0.85,
            ),
            itemBuilder: (context, index) {
              if (index < profiles.length) {
                final p = profiles[index];
                return GestureDetector(
                  onTap: () {
                    userState.setProfile(p);
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const MainScreen()),
                    );
                  },
                  child: Column(
                    children: [
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: p.isKids ? const Color(0xFF0071EB) : const Color(0xFFE50914),
                          image: DecorationImage(
                            image: NetworkImage(
                              p.isKids
                                  ? 'https://images.unsplash.com/photo-1566492031773-4f4e44671857?w=150&auto=format&fit=crop&q=60'
                                  : 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=150&auto=format&fit=crop&q=60',
                            ),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        p.name,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                );
              }

              // Add profile button
              return Column(
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey[700]!, width: 1.5),
                    ),
                    child: const Icon(Icons.add, color: Colors.white, size: 36),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add Profile',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
