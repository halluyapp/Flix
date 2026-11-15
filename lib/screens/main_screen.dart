import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  static const String _tabKey = 'flix_last_selected_tab';
  int _currentIndex = 0;
  final Set<int> _visitedTabs = {0};

  @override
  void initState() {
    super.initState();
    _restoreLastTab();
  }

  Future<void> _restoreLastTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastTab = prefs.getInt(_tabKey);
      if (lastTab != null && lastTab >= 0 && lastTab < _tabCount && mounted) {
        setState(() {
          _currentIndex = lastTab;
          _visitedTabs.add(lastTab);
        });
      }
    } catch (_) {}
  }

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
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt(_tabKey, index);
    }).catchError((_) {});
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
