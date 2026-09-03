# Remove Sleepwing

Sleepwing does not install a privileged helper or kernel extension.

1. Open Sleepwing → Connections and remove every installed Agent integration. This
   lets Sleepwing restore only the hook or plugin entries it owns.
2. Turn off Launch at Login in Sleepwing, then quit the app.
3. Move `Sleepwing.app` to the Trash.
4. To erase local Sleepwing data, remove
   `~/Library/Application Support/Perch`.
5. To erase macOS preferences, run:

   ```sh
   defaults delete app.sleepwing.Sleepwing
   ```

Sleepwing may leave adjacent configuration backup files created during integration
installation. Inspect those backups before deleting them; they may be useful if
the provider configuration needs to be restored manually.
