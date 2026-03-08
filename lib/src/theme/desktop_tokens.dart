import 'package:flutter/material.dart';

@immutable
class DesktopTokens extends ThemeExtension<DesktopTokens> {
  const DesktopTokens({
    required this.frameMaxWidthCompact,
    required this.frameMaxWidthStandard,
    required this.frameMaxWidthUltraWide,
    required this.sidebarWidth,
    required this.sectionGap,
    required this.contentGap,
    required this.panelRadius,
    required this.cardRadius,
    required this.panelElevation,
    required this.hoverOpacity,
    required this.focusOpacity,
    required this.quickMotion,
    required this.normalMotion,
  });

  final double frameMaxWidthCompact;
  final double frameMaxWidthStandard;
  final double frameMaxWidthUltraWide;
  final double sidebarWidth;
  final double sectionGap;
  final double contentGap;
  final double panelRadius;
  final double cardRadius;
  final double panelElevation;
  final double hoverOpacity;
  final double focusOpacity;
  final Duration quickMotion;
  final Duration normalMotion;

  static const DesktopTokens defaults = DesktopTokens(
    frameMaxWidthCompact: 1240,
    frameMaxWidthStandard: 1440,
    frameMaxWidthUltraWide: 1720,
    sidebarWidth: 300,
    sectionGap: 20,
    contentGap: 16,
    panelRadius: 20,
    cardRadius: 16,
    panelElevation: 0,
    hoverOpacity: 0.09,
    focusOpacity: 0.14,
    quickMotion: Duration(milliseconds: 140),
    normalMotion: Duration(milliseconds: 220),
  );

  @override
  DesktopTokens copyWith({
    double? frameMaxWidthCompact,
    double? frameMaxWidthStandard,
    double? frameMaxWidthUltraWide,
    double? sidebarWidth,
    double? sectionGap,
    double? contentGap,
    double? panelRadius,
    double? cardRadius,
    double? panelElevation,
    double? hoverOpacity,
    double? focusOpacity,
    Duration? quickMotion,
    Duration? normalMotion,
  }) {
    return DesktopTokens(
      frameMaxWidthCompact: frameMaxWidthCompact ?? this.frameMaxWidthCompact,
      frameMaxWidthStandard:
          frameMaxWidthStandard ?? this.frameMaxWidthStandard,
      frameMaxWidthUltraWide:
          frameMaxWidthUltraWide ?? this.frameMaxWidthUltraWide,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      sectionGap: sectionGap ?? this.sectionGap,
      contentGap: contentGap ?? this.contentGap,
      panelRadius: panelRadius ?? this.panelRadius,
      cardRadius: cardRadius ?? this.cardRadius,
      panelElevation: panelElevation ?? this.panelElevation,
      hoverOpacity: hoverOpacity ?? this.hoverOpacity,
      focusOpacity: focusOpacity ?? this.focusOpacity,
      quickMotion: quickMotion ?? this.quickMotion,
      normalMotion: normalMotion ?? this.normalMotion,
    );
  }

  @override
  ThemeExtension<DesktopTokens> lerp(
    ThemeExtension<DesktopTokens>? other,
    double t,
  ) {
    if (other is! DesktopTokens) {
      return this;
    }
    return DesktopTokens(
      frameMaxWidthCompact: lerpDouble(
        frameMaxWidthCompact,
        other.frameMaxWidthCompact,
        t,
      ),
      frameMaxWidthStandard: lerpDouble(
        frameMaxWidthStandard,
        other.frameMaxWidthStandard,
        t,
      ),
      frameMaxWidthUltraWide: lerpDouble(
        frameMaxWidthUltraWide,
        other.frameMaxWidthUltraWide,
        t,
      ),
      sidebarWidth: lerpDouble(sidebarWidth, other.sidebarWidth, t),
      sectionGap: lerpDouble(sectionGap, other.sectionGap, t),
      contentGap: lerpDouble(contentGap, other.contentGap, t),
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t),
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t),
      panelElevation: lerpDouble(panelElevation, other.panelElevation, t),
      hoverOpacity: lerpDouble(hoverOpacity, other.hoverOpacity, t),
      focusOpacity: lerpDouble(focusOpacity, other.focusOpacity, t),
      quickMotion: lerpDuration(quickMotion, other.quickMotion, t),
      normalMotion: lerpDuration(normalMotion, other.normalMotion, t),
    );
  }

  static double lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }

  static Duration lerpDuration(Duration a, Duration b, double t) {
    return Duration(
      microseconds:
          (a.inMicroseconds + (b.inMicroseconds - a.inMicroseconds) * t)
              .round(),
    );
  }
}

DesktopTokens desktopTokensOf(BuildContext context) {
  return Theme.of(context).extension<DesktopTokens>() ?? DesktopTokens.defaults;
}
