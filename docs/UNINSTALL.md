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

## Before you go

If something made you uninstall, one line in the **[Q&A discussions](https://github.com/lttxzmj/sleepwing/discussions/categories/q-a)**
(English or Chinese) is genuinely useful — Sleepwing sends no telemetry, so an
uninstall is completely silent to us and we have no other way to learn the
reason. No logs, paths or screenshots needed; "the pet got in the way" is a
complete answer.

离开前：如果有什么让你卸载了，去 **[Q&A 讨论区](https://github.com/lttxzmj/sleepwing/discussions/categories/q-a)** 留一句就很有用。
Sleepwing 不发任何遥测，所以卸载对我们是完全静默的，没有别的途径知道原因。
不用附日志、路径或截图，"桌宠挡住东西了"就是一个完整的回答。

