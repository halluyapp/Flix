import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_state_service.dart';
import '../widgets/media_card.dart';
import 'profile_screen.dart';

class MyFlixScreen extends StatelessWidget {
  const MyFlixScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final userState = Provider.of<UserStateService>(context);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'My Flix',
          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.switch_account, color: Colors.white),
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundImage: NetworkImage(userState.currentProfile.avatarUrl),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userState.currentProfile.name,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Text('Switch Profile', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'My List',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (userState.myList.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                alignment: Alignment.center,
                child: const Text(
                  'Your watch list is empty.\nTap "+ My List" on any title to save it here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.68,
                ),
                itemCount: userState.myList.length,
                itemBuilder: (context, index) {
                  return MediaCard(item: userState.myList[index]);
                },
              ),
          ],
        ),
      ),
    );
  }
}
