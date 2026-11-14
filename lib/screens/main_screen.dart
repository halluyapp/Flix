import 'package:flutter/material.dart';
import 'clips_screen.dart';
import 'home_screen.dart';
import 'new_and_hot_screen.dart';
import 'search_screen.dart';
import 'my_flix_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const int _tabCount = 5;
  int _currentIndex = 0;
  final Set<int> _visitedTabs = {0};

  Widget _screenFor(int index) {
    switch (index) {
      case 0:
        return const HomeScreen();
      case 1:
        return const ClipsScreen();
      case 2:
        return const NewAndHotScreen();
      case 3:
        return const SearchScreen();
      case 4:
        return const MyFlixScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  void _selectTab(int index) {
    if (index < 0 || index >= _tabCount) return;
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      body: IndexedStack(
        index: _currentIndex,
        children: List.generate(
          _tabCount,
          (index) => _visitedTabs.contains(index)
              ? _screenFor(index)
              : const SizedBox.shrink(),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _selectTab,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.play_circle_outline), label: 'Clips'),
          BottomNavigationBarItem(
              icon: Icon(Icons.video_library_outlined), label: 'New & Hot'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: 'My Flix'),
        ],
      ),
    );
  }
}
