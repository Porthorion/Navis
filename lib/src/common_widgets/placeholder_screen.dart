import 'package:flutter/material.dart';

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({required this.title, super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(subtitle!, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
