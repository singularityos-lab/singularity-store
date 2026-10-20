using Gtk;
using GLib;

namespace Singularity.Apps.Store {

    public class PluginEntry : Object {
        public string id;
        public string module;
        public string name;
        public string summary;
        public string author;
        public string app_id;
        public string host_dir;
        public string version;
        public string? icon;
        public string? url;
        public string? sha256;
    }

    public class PluginCatalog : Object {
        public const string INDEX = "https://raw.githubusercontent.com/singularityos-lab/singularity-plugins/main/index.json";
        public const string PUBLIC_KEY = "es4syb41iCgyKI8jqUFLIXKPvq0Ur0zUybHhE2bQvhQ=";

        public GenericArray<PluginEntry> entries = new GenericArray<PluginEntry> ();

        private static string arch () {
            var uts = Posix.utsname ();
            return uts.machine == "aarch64" || uts.machine == "arm64" ? "aarch64" : "x86_64";
        }

        public static string install_root () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "app-plugins");
        }

        public static string install_dir (PluginEntry p) {
            return Path.build_filename (install_root (), p.host_dir, p.id);
        }

        public static bool installed (PluginEntry p) {
            return FileUtils.test (install_dir (p), FileTest.IS_DIR);
        }

        public async void load () throws Error {
            string url = Environment.get_variable ("SINGULARITY_PLUGIN_INDEX") ?? INDEX;
            var session = new Soup.Session ();
            session.user_agent = "Singularity-Store";
            var index = yield fetch (session, url);
            var sig = yield fetch (session, url + ".sig");
            var signature = Base64.decode (text_of (sig).strip ());
            var key = Base64.decode (PUBLIC_KEY);
            if (!store_plugin_verify (key, index.get_data (), signature))
                throw new IOError.FAILED (_("The plugin catalog signature is not valid"));
            parse (text_of (index));
        }

        private static string text_of (Bytes bytes) {
            var sb = new StringBuilder.sized (bytes.get_size () + 1);
            sb.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            return sb.str;
        }

        private static async Bytes fetch (Soup.Session session, string url) throws Error {
            if (url.has_prefix ("file://")) {
                uint8[] data;
                FileUtils.get_data (File.new_for_uri (url).get_path (), out data);
                return new Bytes (data);
            }
            var msg = new Soup.Message ("GET", url);
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
            if (msg.status_code != 200) throw new IOError.FAILED (_("Could not download the plugin catalog (%u)").printf (msg.status_code));
            return bytes;
        }

        private void parse (string text) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (text);
            var arr = parser.get_root ().get_object ().get_array_member ("plugins");
            var list = new GenericArray<PluginEntry> ();
            for (uint i = 0; i < arr.get_length (); i++) {
                var o = arr.get_object_element (i);
                var p = new PluginEntry ();
                p.id = o.get_string_member ("id");
                p.module = o.get_string_member_with_default ("module", p.id);
                p.name = o.get_string_member ("name");
                p.summary = o.get_string_member_with_default ("summary", "");
                p.author = o.get_string_member_with_default ("author", "");
                p.app_id = o.get_string_member ("app");
                p.host_dir = o.get_string_member ("host_dir");
                p.version = o.get_string_member_with_default ("version", "");
                p.icon = o.has_member ("icon") ? o.get_string_member ("icon") : null;
                if (o.has_member ("bundles")) {
                    var b = o.get_object_member ("bundles");
                    if (b.has_member (arch ())) {
                        var a = b.get_object_member (arch ());
                        p.url = a.get_string_member ("url");
                        p.sha256 = a.get_string_member ("sha256");
                    }
                }
                if (p.host_dir.contains ("/") || p.id.contains ("/") || p.host_dir.has_prefix (".") || p.id.has_prefix (".")) continue;
                list.add (p);
            }
            entries = list;
        }

        public static bool app_installed (string app_id) {
            return new DesktopAppInfo (app_id + ".desktop") != null;
        }

        public async void install (PluginEntry p) throws Error {
            if (p.url == null || p.sha256 == null) throw new IOError.NOT_SUPPORTED (_("This plugin is not available for this computer"));
            var session = new Soup.Session ();
            var bytes = yield fetch (session, p.url);
            var sum = Checksum.compute_for_bytes (ChecksumType.SHA256, bytes);
            if (sum != p.sha256) throw new IOError.FAILED (_("The downloaded plugin does not match the catalog"));
            string dir = install_dir (p);
            string tmp = dir + ".partial";
            remove_tree (tmp);
            DirUtils.create_with_parents (tmp, 0755);
            string archive = Path.build_filename (tmp, "bundle.tar.gz");
            FileUtils.set_data (archive, bytes.get_data ());
            var proc = new Subprocess.newv ({ "tar", "-xzf", archive, "-C", tmp, "--no-same-owner", "--no-same-permissions" }, SubprocessFlags.NONE);
            yield proc.wait_async (null);
            FileUtils.unlink (archive);
            if (!proc.get_successful ()) throw new IOError.FAILED (_("Could not unpack the plugin"));
            if (!has_plugin_file (tmp)) throw new IOError.FAILED (_("The bundle has no plugin description"));
            remove_tree (dir);
            FileUtils.rename (tmp, dir);
            set_enabled (p, true);
        }

        private static bool has_plugin_file (string dir) {
            try {
                var d = Dir.open (dir);
                string? name;
                while ((name = d.read_name ()) != null) {
                    var path = Path.build_filename (dir, name);
                    if (name.has_suffix (".plugin")) return true;
                    if (FileUtils.test (path, FileTest.IS_DIR) && has_plugin_file (path)) return true;
                }
            } catch (FileError e) {
            }
            return false;
        }

        public void remove (PluginEntry p) {
            set_enabled (p, false);
            remove_tree (install_dir (p));
        }

        private static void remove_tree (string path) {
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            if (FileUtils.test (path, FileTest.IS_DIR) && !FileUtils.test (path, FileTest.IS_SYMLINK)) {
                try {
                    var d = Dir.open (path);
                    string? name;
                    while ((name = d.read_name ()) != null) remove_tree (Path.build_filename (path, name));
                } catch (FileError e) {
                }
                DirUtils.remove (path);
            } else {
                FileUtils.unlink (path);
            }
        }

        private static void set_enabled (PluginEntry p, bool on) {
            var source = SettingsSchemaSource.get_default ();
            if (source == null || source.lookup ("dev.sinty.desktop", true) == null) return;
            var s = new GLib.Settings ("dev.sinty.desktop");
            string[] list = {};
            foreach (var m in s.get_strv ("enabled-plugins")) if (m != p.module) list += m;
            if (on) list += p.module;
            s.set_strv ("enabled-plugins", list);
        }
    }

    public class PluginsPage : Box {
        private PluginCatalog catalog = new PluginCatalog ();
        private Box chips;
        private Box list;
        private Label status;
        private string current = "";
        private bool loaded;

        public PluginsPage () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            chips = new Box (Orientation.HORIZONTAL, 6);
            chips.margin_start = chips.margin_end = 12;
            chips.margin_top = 8;
            append (chips);
            status = new Label ("");
            status.add_css_class ("dim-label");
            status.margin_top = 24;
            status.visible = false;
            append (status);
            list = new Box (Orientation.VERTICAL, 0);
            list.margin_start = list.margin_end = 12;
            list.margin_top = 8;
            list.margin_bottom = 24;
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.child = list;
            append (sw);
        }

        public void ensure_loaded () {
            if (loaded) return;
            loaded = true;
            load.begin ();
        }

        private async void load () {
            status.label = _("Loading plugins");
            status.visible = true;
            try {
                yield catalog.load ();
            } catch (Error e) {
                status.label = e.message;
                loaded = false;
                return;
            }
            status.visible = false;
            build_chips ();
            fill ();
        }

        private void build_chips () {
            Widget? c;
            while ((c = chips.get_first_child ()) != null) chips.remove (c);
            var apps = new GenericArray<string> ();
            foreach (var p in catalog.entries.data) {
                if (!PluginCatalog.app_installed (p.app_id)) continue;
                bool seen = false;
                foreach (var a in apps.data) if (a == p.app_id) seen = true;
                if (!seen) apps.add (p.app_id);
            }
            var all = new ToggleButton.with_label (_("All Apps"));
            all.add_css_class ("pill");
            all.active = current == "";
            all.toggled.connect (() => {
                if (!all.active) return;
                current = "";
                build_chips ();
                fill ();
            });
            chips.append (all);
            foreach (var app_id in apps.data) {
                var info = new DesktopAppInfo (app_id + ".desktop");
                var b = new ToggleButton ();
                b.add_css_class ("pill");
                var box = new Box (Orientation.HORIZONTAL, 6);
                var icon = new Image.from_gicon (info.get_icon ());
                icon.pixel_size = 16;
                box.append (icon);
                box.append (new Label (info.get_display_name ()));
                b.child = box;
                b.active = current == app_id;
                string id = app_id;
                b.toggled.connect (() => {
                    if (!b.active) return;
                    current = id;
                    build_chips ();
                    fill ();
                });
                chips.append (b);
            }
        }

        private void fill () {
            Widget? c;
            while ((c = list.get_first_child ()) != null) list.remove (c);
            int shown = 0;
            foreach (var p in catalog.entries.data) {
                if (!PluginCatalog.app_installed (p.app_id)) continue;
                if (current != "" && p.app_id != current) continue;
                list.append (card (p));
                shown++;
            }
            status.visible = shown == 0;
            if (shown == 0) status.label = _("No plugins for your apps yet");
        }

        private Widget card (PluginEntry p) {
            var row = new Box (Orientation.HORIZONTAL, 12);
            row.add_css_class ("store-app-card");
            row.margin_top = row.margin_bottom = 4;
            var info = new DesktopAppInfo (p.app_id + ".desktop");
            var icon = p.icon != null ? new Image.from_icon_name (p.icon) : new Image.from_gicon (info.get_icon ());
            icon.pixel_size = 48;
            row.append (icon);
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            var name = new Label (p.name);
            name.xalign = 0;
            name.add_css_class ("store-app-name");
            texts.append (name);
            var meta = new Label ("%s · %s".printf (info.get_display_name (), p.author));
            meta.xalign = 0;
            meta.add_css_class ("store-app-developer");
            texts.append (meta);
            var sum = new Label (p.summary);
            sum.xalign = 0;
            sum.wrap = true;
            sum.add_css_class ("store-app-summary");
            texts.append (sum);
            row.append (texts);
            var btn = new Button.with_label (PluginCatalog.installed (p) ? _("Remove") : _("Get"));
            btn.add_css_class ("store-install-btn");
            btn.valign = Align.CENTER;
            btn.clicked.connect (() => {
                if (PluginCatalog.installed (p)) {
                    catalog.remove (p);
                    btn.label = _("Get");
                    return;
                }
                btn.sensitive = false;
                btn.label = _("Installing");
                catalog.install.begin (p, (obj, res) => {
                    btn.sensitive = true;
                    try {
                        catalog.install.end (res);
                        btn.label = _("Remove");
                    } catch (Error e) {
                        btn.label = _("Get");
                        var root = get_root () as Singularity.Widgets.Window;
                        if (root != null) root.add_toast (new Singularity.Widgets.Toast (e.message));
                    }
                });
            });
            row.append (btn);
            return row;
        }
    }
}
