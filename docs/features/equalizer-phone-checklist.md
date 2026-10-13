# Graph-first EQ: physical-phone checklist

Install the delivered **Navis Dev** APK. Its application ID is
`com.navis.app.navis.dev`; the standalone Navis installation should remain
separate. Installation and listening checks are deferred to the tester.

Use music you know, and save any existing work before testing discard or delete.

- **Graph editing:** select a handle, then drag immediately. Advanced changes
  frequency and gain; Simple/10-band changes gain only. The handle should not
  jump when grabbed, and a value bubble should stay visible above your finger.
  The selected band should be obvious (shaded curve, large numbered handle)
  in your usual theme. Q should move smoothly between Wider and Narrower. One
  drag should require one Undo; Redo should restore it.
- **Exact values:** tap Frequency, Gain, Q, and Preamp. Enter a precise value,
  then Done. Cancel and Back should restore the sound from before editing.
  Incomplete or invalid text should retain the last valid preview and prevent
  Done. Opening and accepting an untouched value should preserve its precision.
  The graph should remain visible while the keyboard is open.
- **Filters:** try all six Advanced types. Pass/notch filters should show gain
  as Not applicable. Add selects a neutral 1 kHz band; Delete removes only the
  selected band. Disabled bands remain hollow and disabled while edited.
  Overlapping bands should be reachable through the chooser or the band strip;
  after choosing one in the strip, dragging the stack should move that band.
- **Draft recovery:** edit two named presets and two modes, switch between them,
  leave the page, then restart Navis Dev. Each should resume its own work with
  `*`. Built-ins should offer Save as new; user presets should save in place.
  Discard should confirm removal across that preset's modes. Rename should
  retain work; deletion with drafts should offer explicit preservation/removal.
- **Advanced protection:** return to a fixed mode after editing Advanced, then
  choose Edit in Advanced. Resume should recover the earlier Advanced draft;
  Create a new preset should preserve both the original draft and the current
  curve under the new name.
- **AutoEQ:** import a parametric and a fixed-band profile. Confirm the original
  band count, mode, preamp, and source details. Edit, save, export, and reimport;
  untouched values and source attribution should remain intact. Fixed imports
  should keep their original frequencies and Q.
- **Output and listening:** compare enabled/bypassed playback. Change preamp and
  check the labeled Output response, attenuation, and effective output gain.
  The authored curve and band handles should remain independent of attenuation.
  Try seek, pause/resume, track changes, and background playback during edits.
- **Layouts and access:** test portrait/landscape (landscape should place the
  controls beside the graph), 200% text, light/dark themes, long preset names,
  and an open keyboard. All selected-band, Done/Cancel, and
  Save/Discard controls should remain reachable. With TalkBack, verify band
  selection, labels/units, numeric entry, and increment/decrement actions.
- **Real devices and performance:** try your headphones, Bluetooth connection,
  and speaker route; check interruptions and reconnects. Drag continuously in
  a 32-band preset and report any stutter, delayed sound changes, or mismatch
  between the visible draft and audio. Device-specific automatic preset
  switching is outside this revision.

For an issue, note the preset/mode, filter type, action, device/audio route,
whether playback was active, and whether a restart recovered the draft.
