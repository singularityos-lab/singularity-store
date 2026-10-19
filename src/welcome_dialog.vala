using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Store {

    public class WelcomeScene : Widget {
        private const double W = 640;
        private const double H = 340;
        private const double[] SLOTS = {
            190, 150, 76,
            450, 150, 76,
            108, 88, 58,
            532, 88, 58,
            118, 240, 54,
            522, 240, 54,
            42, 170, 42,
            598, 170, 42,
            250, 62, 40,
            390, 62, 40,
            262, 276, 38,
            378, 276, 38
        };

        private Gdk.Paintable? center = null;
        private Gdk.Paintable[] icons = {};
        private double phase = 0;
        private uint tick = 0;

        public WelcomeScene (string center_icon) {
            add_css_class ("store-welcome-scene");
            var theme = IconTheme.get_for_display (Gdk.Display.get_default ());
            center = theme.lookup_icon (center_icon, null, 256, 1, TextDirection.NONE, 0);
            map.connect (() => {
                var gtk = Gtk.Settings.get_default ();
                if (gtk != null && !gtk.gtk_enable_animations) return;
                tick = add_tick_callback ((w, clock) => {
                    phase = (clock.get_frame_time () / 1000000.0) % 6.0 / 6.0;
                    queue_draw ();
                    return Source.CONTINUE;
                });
            });
            unmap.connect (() => {
                if (tick != 0) remove_tick_callback (tick);
                tick = 0;
            });
        }

        public bool full {
            get { return icons.length >= SLOTS.length / 3; }
        }

        public void add_icon (Gdk.Paintable paintable) {
            if (full) return;
            icons += paintable;
            queue_draw ();
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            minimum = orientation == Orientation.HORIZONTAL ? 280 : 150;
            natural = orientation == Orientation.HORIZONTAL ? (int) W : (int) H;
        }

        public override void snapshot (Snapshot snapshot) {
            double width = get_width ();
            double height = get_height ();
            double scale = double.min (width / W, height / H);
            double dx = (width - W * scale) / 2;
            double dy = (height - H * scale) / 2;
            var bounds = Graphene.Rect ().init ((float) dx, (float) dy, (float) (W * scale), (float) (H * scale));
            var rounded = Gsk.RoundedRect ().init_from_rect (bounds, (float) (18 * scale));
            var shadow = Gdk.RGBA () { red = 0, green = 0, blue = 0, alpha = 0.28f };
            snapshot.append_outset_shadow (rounded, shadow, 0, (float) (12 * scale), 0, (float) (30 * scale));
            snapshot.push_rounded_clip (rounded);

            var cr = snapshot.append_cairo (bounds);
            cr.translate (dx, dy);
            cr.scale (scale, scale);
            glow (cr);

            for (int i = 0; i < icons.length; i++) {
                double size = SLOTS[i * 3 + 2];
                double bob = Math.sin ((phase + i * 0.13) * 2 * Math.PI) * 4;
                draw_icon (snapshot, icons[i], dx, dy, scale, SLOTS[i * 3], SLOTS[i * 3 + 1] + bob, size);
            }
            if (center != null) draw_icon (snapshot, center, dx, dy, scale, W / 2, H / 2, 132);
            snapshot.pop ();
        }

        private static void draw_icon (Snapshot snapshot, Gdk.Paintable icon, double dx, double dy, double scale, double cx, double cy, double size) {
            double s = size * scale;
            snapshot.save ();
            snapshot.translate (Graphene.Point () { x = (float) (dx + cx * scale - s / 2), y = (float) (dy + cy * scale - s / 2) });
            icon.snapshot (snapshot, s, s);
            snapshot.restore ();
        }

        private void glow (Cairo.Context cr) {
            cr.set_source_rgb (0x0e / 255.0, 0x0f / 255.0, 0x12 / 255.0);
            cr.paint ();
            var a = get_color ();
            var g = new Cairo.Pattern.radial (W / 2, H / 2, 10, W / 2, H / 2, 300);
            g.add_color_stop_rgba (0, a.red, a.green, a.blue, 0.55);
            g.add_color_stop_rgba (0.45, a.red, a.green, a.blue, 0.16);
            g.add_color_stop_rgba (1, a.red, a.green, a.blue, 0);
            cr.set_source (g);
            cr.paint ();
        }
    }

    public class WelcomeDialog : AppDialog {
        public signal void discover_collection ();
        public signal void dismissed (bool show_again);

        private const string POPULAR_URL = "https://flathub.org/api/v2/collection/popular?page=1&per_page=30";
        private const string CSS = """
.store-welcome-scene {
    color: @accent_color;
}

.store-welcome-title {
    font-size: 24px;
    font-weight: 800;
    margin-bottom: 8px;
}

.store-welcome-body {
    font-size: 15px;
    color: alpha(@window_fg_color, 0.7);
}
""";

        private Stack stack;
        private StepIsland island;
        private int pages = 0;
        private int current = 0;
        private int offline_index = -1;
        private WelcomeScene flathub_scene;
        private WelcomeScene? collection_scene = null;
        private CheckButton dont_show;
        private Soup.Session session = new Soup.Session ();
        private NetworkMonitor monitor = NetworkMonitor.get_default ();
        private ulong monitor_handler = 0;
        private bool flathub_requested = false;
        private string[] pending_collection = {};
        private bool answered = false;

        public WelcomeDialog (Gtk.Application app, Gtk.Window parent, bool with_collection) {
            base (app, true);
            transient_for = parent;
            set_default_size (720, 640);
            resizable = false;
            session.timeout = 12;

            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_APPLICATION);

            stack = new Stack ();
            stack.hexpand = true;
            stack.vexpand = true;
            stack.transition_type = StackTransitionType.SLIDE_LEFT_RIGHT;
            stack.transition_duration = 260;

            if (!monitor.network_available) {
                offline_index = pages;
                add_page (new WelcomeScene ("network-error"),
                    _("Connect to the Internet"),
                    _("The Store needs a connection to show and install apps. Turn on Wi-Fi or plug in a cable, and this page moves on by itself."));
            }
            flathub_scene = new WelcomeScene ("dev.sinty.store");
            add_page (flathub_scene,
                _("Your Favorite Apps Are Already Here"),
                _("Browsers, music, chat, games and the tools you use every day are ready to install, and the Store keeps them up to date for you."));
            if (with_collection) {
                collection_scene = new WelcomeScene ("emblem-singularity");
                add_page (collection_scene,
                    _("Meet the Singularity Apps"),
                    _("Discover our own collection: native apps made for this desktop, light, consistent and built to work together."));
            }

            string[] names = {};
            for (int i = 0; i < pages; i++) names += "";
            island = new StepIsland (names);
            island.margin_bottom = 4;
            island.back_clicked.connect (() => go (current - 1));
            island.next_clicked.connect (on_next_clicked);

            dont_show = new CheckButton.with_label (_("Don't show this again"));
            dont_show.halign = Align.CENTER;
            dont_show.margin_bottom = 14;

            var box = new Box (Orientation.VERTICAL, 10);
            box.append (stack);
            box.append (island);
            box.append (dont_show);
            content_box.append (box);

            go (0);
            monitor_handler = monitor.network_changed.connect (on_network_changed);
            if (monitor.network_available) load_flathub_icons ();
            close_request.connect (() => {
                if (monitor_handler != 0) {
                    monitor.disconnect (monitor_handler);
                    monitor_handler = 0;
                }
                if (!answered) {
                    answered = true;
                    dismissed (!dont_show.active);
                }
                return false;
            });
        }

        public void set_collection_icons (string[] urls) {
            if (collection_scene == null) return;
            if (!monitor.network_available) {
                pending_collection = urls;
                return;
            }
            foreach (var url in urls) load_icon (url, collection_scene);
        }

        private void add_page (WelcomeScene scene, string title, string body) {
            var col = new Box (Orientation.VERTICAL, 0);
            col.margin_start = 32;
            col.margin_end = 32;
            scene.vexpand = true;
            scene.margin_top = 4;
            scene.margin_bottom = 24;
            col.append (scene);
            var title_lbl = new Label (title);
            title_lbl.add_css_class ("store-welcome-title");
            title_lbl.wrap = true;
            title_lbl.justify = Justification.CENTER;
            col.append (title_lbl);
            var body_lbl = new Label (body);
            body_lbl.add_css_class ("store-welcome-body");
            body_lbl.wrap = true;
            body_lbl.justify = Justification.CENTER;
            body_lbl.max_width_chars = 52;
            body_lbl.halign = Align.CENTER;
            col.append (body_lbl);
            stack.add_named (col, pages.to_string ());
            pages++;
        }

        private void go (int index) {
            if (index < 0 || index >= pages) return;
            stack.transition_type = index >= current ? StackTransitionType.SLIDE_LEFT : StackTransitionType.SLIDE_RIGHT;
            current = index;
            stack.visible_child_name = index.to_string ();
            island.step = index;
            island.back_visible = index > 0;
            if (index == offline_index) {
                island.next_label = _("Network Settings");
            } else if (index < pages - 1) {
                island.next_label = _("Next");
            } else if (collection_scene != null) {
                island.next_label = _("Discover the Collection");
            } else {
                island.next_label = _("Start Browsing");
            }
        }

        private void on_next_clicked () {
            if (current == offline_index) {
                open_network_settings ();
            } else if (current < pages - 1) {
                go (current + 1);
            } else {
                finish (collection_scene != null);
            }
        }

        private void on_network_changed (bool available) {
            if (!available) return;
            load_flathub_icons ();
            if (pending_collection.length > 0) {
                var urls = pending_collection;
                pending_collection = {};
                set_collection_icons (urls);
            }
            if (current == offline_index) go (current + 1);
        }

        private void load_flathub_icons () {
            if (flathub_requested) return;
            flathub_requested = true;
            var msg = new Soup.Message ("GET", POPULAR_URL);
            session.send_and_read_async.begin (msg, Priority.LOW, null, (obj, res) => {
                try {
                    var bytes = session.send_and_read_async.end (res);
                    var parser = new Json.Parser ();
                    parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
                    var root_obj = root.get_object ();
                    if (!root_obj.has_member ("hits")) return;
                    root_obj.get_array_member ("hits").foreach_element ((arr, i, node) => {
                        if (node.get_node_type () != Json.NodeType.OBJECT) return;
                        var hit = node.get_object ();
                        if (hit.has_member ("icon") && !hit.get_null_member ("icon")) {
                            load_icon (hit.get_string_member ("icon"), flathub_scene);
                        }
                    });
                } catch (Error e) {
                    flathub_requested = false;
                }
            });
        }

        private void load_icon (string url, WelcomeScene scene) {
            if (scene.full || url == "") return;
            if (!url.has_prefix ("http://") && !url.has_prefix ("https://")) {
                try {
                    var file = url.has_prefix ("file://") ? File.new_for_uri (url) : File.new_for_path (url);
                    scene.add_icon (Gdk.Texture.from_file (file));
                } catch (Error e) {
                }
                return;
            }
            var msg = new Soup.Message ("GET", url);
            session.send_and_read_async.begin (msg, Priority.LOW, null, (obj, res) => {
                try {
                    var bytes = session.send_and_read_async.end (res);
                    var stream = new MemoryInputStream.from_bytes (bytes);
                    var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (stream, 128, 128, true, null);
                    scene.add_icon (Gdk.Texture.for_pixbuf (pixbuf));
                } catch (Error e) {
                }
            });
        }

        private static void open_network_settings () {
            try {
                var conn = Bus.get_sync (BusType.SESSION, null);
                conn.call.begin ("dev.sinty.desktop", "/dev/sinty/Shell", "dev.sinty.Shell", "OpenSettings",
                    new Variant ("(s)", "network"), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                warning ("Could not open the network settings: %s", e.message);
            }
        }

        private void finish (bool discover) {
            if (!answered) {
                answered = true;
                dismissed (!dont_show.active);
            }
            if (discover) discover_collection ();
            close_dialog ();
        }
    }
}
