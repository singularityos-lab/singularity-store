using Gtk;
using Gdk;
using Pango;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps.Store {

    public class StoreApp : Singularity.Application {

        // Window
        private StoreWindow main_window;
        private Stack main_stack;
        private Gtk.Revealer? sidebar_revealer = null;
        private Gtk.Button? sidebar_active_btn = null;
        private Gtk.SearchEntry gtk_search_entry;
        private Button back_button;

        // HTTP
        private Soup.Session http_session;

        // Settings
        private GLib.Settings? store_settings;

        // State
        private uint search_timeout_id = 0;
        private string current_nav = "discover";
        private bool discover_loaded = false;
        private bool charts_loaded = false;
        private bool recent_loaded = false;
        private string[] installed_app_ids = {};
        private bool installed_load_then_discover = false;
        private string[] pending_update_ids = {};
        private string current_search_query = "";
        private string current_detail_app_id = "";

        // Discover widgets
        private Spinner discover_spinner;
        private ScrolledWindow discover_scroll;
        private Box discover_box;

        // Charts widgets
        private Spinner charts_spinner;
        private ScrolledWindow charts_scroll;
        private Box charts_box;

        // Recently Updated widgets
        private Spinner recent_spinner;
        private ScrolledWindow recent_scroll;
        private Box recent_box;

        // Search / category-browse widgets
        private Spinner search_spinner;
        private Label search_status;
        private ScrolledWindow search_scroll;
        private Box search_result_box;

        // Installed widgets
        private Label installed_status;
        private ScrolledWindow installed_scroll;
        private Box installed_box;

        // Updates widgets
        private Label updates_status;
        private ScrolledWindow updates_scroll;
        private Box updates_box;

        // Detail widgets
        private ScrolledWindow detail_scroll;
        private Box detail_box;
        private Expander install_log_expander;
        private TextView install_log_text;

        // ============================================================
        // Lifecycle
        // ============================================================

        public StoreApp () {
            Object (application_id: "dev.sinty.store", flags: ApplicationFlags.FLAGS_NONE);
        }

        protected override void startup () {
            base.startup ();
            http_session = new Soup.Session ();
            // Shorter timeout so the "Could not connect to Flathub" screen
            // appears promptly when the API is unreachable/down, instead of the
            // window sitting blank for half a minute.
            http_session.timeout = 12;
            load_settings ();
            setup_styles ();
        }

        private void load_settings () {
            try {
                var source = SettingsSchemaSource.get_default ();
                if (source != null && source.lookup ("dev.sinty.store", true) != null) {
                    store_settings = new GLib.Settings ("dev.sinty.store");
                } else {
                    try {
                        string exe_path = FileUtils.read_link ("/proc/self/exe");
                        var data_dir = File.new_for_path (exe_path).get_parent ().get_child ("data");
                        if (data_dir.query_exists ()) {
                            var cs = new SettingsSchemaSource.from_directory (data_dir.get_path (), source, true);
                            var schema = cs.lookup ("dev.sinty.store", true);
                            if (schema != null) {
                                store_settings = new GLib.Settings.full (schema, null, null);
                            }
                        }
                    } catch (Error e2) {
                        warning ("Could not load store schemas from build dir: %s", e2.message);
                    }
                }
            } catch (Error e) {
                warning ("Settings init error: %s", e.message);
            }
        }

        protected override void activate () {
            if (main_window != null) {
                main_window.present ();
                return;
            }

            main_window = new StoreWindow (this);
            main_stack = main_window.main_stack;

            setup_toolbar ();
            setup_sidebar ();

            main_stack.transition_type = StackTransitionType.CROSSFADE;
            main_stack.transition_duration = 200;

            setup_discover_view ();
            setup_charts_view ();
            setup_recent_view ();
            setup_search_view ();
            setup_installed_view ();
            setup_updates_view ();
            setup_detail_view ();

            main_window.set_content (main_stack);
            main_window.present ();

            installed_load_then_discover = true;
            refresh_installed_async ();
        }

        // ============================================================
        // Toolbar
        // ============================================================

        private void setup_toolbar () {
            main_window.add_bubble_icon ("sidebar-show-symbolic", "Toggle Sidebar", () => {
                main_window.set_sidebar_visible (!main_window.get_sidebar_visible ());
            });

            back_button = main_window.add_bubble_icon ("go-previous-symbolic", "Back",
                                                      () => on_back_clicked ());
            back_button.visible = false;

            var search_bubble = main_window.add_bubble_search ("Search apps...", (t) => {
                current_search_query = t.strip ();
                if (search_timeout_id != 0) {
                    Source.remove (search_timeout_id);
                    search_timeout_id = 0;
                }
                if (current_search_query == "") {
                    show_view (current_nav);
                    back_button.visible = false;
                    return;
                }
                search_timeout_id = Timeout.add (200, do_search_timeout);
            });
            gtk_search_entry = search_bubble.entry;
            // Type-ahead: start typing anywhere in the window to focus search.
            gtk_search_entry.set_key_capture_widget (main_window);
        }

        private void on_back_clicked () {
            show_view (current_nav);
            back_button.visible = false;
            gtk_search_entry.text = "";
        }

        private void on_search_changed () {
            current_search_query = gtk_search_entry.text.strip ();
            if (search_timeout_id != 0) {
                Source.remove (search_timeout_id);
                search_timeout_id = 0;
            }
            if (current_search_query == "") {
                show_view (current_nav);
                back_button.visible = false;
                return;
            }
            search_timeout_id = Timeout.add (200, do_search_timeout);
        }

        private bool do_search_timeout () {
            search_timeout_id = 0;
            if (current_search_query != "") {
                do_search (current_search_query);
            }
            return false;
        }

        // ============================================================
        // Sidebar  - uses AppSidebar from libsingularity
        // ============================================================

        private void setup_sidebar () {
            var sidebar = main_window.sidebar;
            var box = sidebar.box;

            var featured_btn = make_sidebar_button ("Featured", "starred-symbolic");
            featured_btn.clicked.connect (() => {
                set_sidebar_active (featured_btn);
                current_nav = "discover";
                show_view ("discover");
                gtk_search_entry.text = "";
                back_button.visible = false;
            });
            box.append(featured_btn);

            var popular_btn = make_sidebar_button ("Popular", "view-list-symbolic");
            popular_btn.clicked.connect (() => {
                set_sidebar_active (popular_btn);
                current_nav = "charts";
                show_view ("charts");
                gtk_search_entry.text = "";
                back_button.visible = false;
            });
            box.append(popular_btn);

            var recent_btn = make_sidebar_button ("Recently Updated", "software-update-available-symbolic");
            recent_btn.clicked.connect (() => {
                set_sidebar_active (recent_btn);
                current_nav = "recent";
                show_view ("recent");
                gtk_search_entry.text = "";
                back_button.visible = false;
            });
            box.append(recent_btn);

            box.append(new Separator (Orientation.HORIZONTAL));

            // ── Categories ───────────────────────────────────────────
            box.append(new Singularity.Widgets.SidebarSectionLabel ("Categories"));

            string[] cat_labels = {
                "Education", "Games", "Graphics", "Internet", "Office",
                "Science", "System", "Video & Audio", "Development"
            };
            string[] cat_ids = {
                "Education", "Game", "Graphics", "Network", "Office",
                "Science", "System", "Video", "Development"
            };
            string[] cat_icons = {
                "accessories-dictionary-symbolic",
                "applications-games-symbolic",
                "applications-graphics-symbolic",
                "network-workgroup-symbolic",
                "x-office-document-symbolic",
                "applications-science-symbolic",
                "applications-system-symbolic",
                "video-x-generic-symbolic",
                "applications-engineering-symbolic"
            };

            for (int i = 0; i < cat_labels.length; i++) {
                string lbl_text  = cat_labels[i];
                string cat_id    = cat_ids[i];
                string icon_name = cat_icons[i];
                var cat_btn = make_sidebar_button (lbl_text, icon_name);
                cat_btn.clicked.connect (() => {
                    set_sidebar_active (cat_btn);
                    browse_category (cat_id);
                    gtk_search_entry.text = "";
                });
                box.append(cat_btn);
            }

            box.append(new Separator (Orientation.HORIZONTAL));

            // ── Library ──────────────────────────────────────────────
            var installed_btn = make_sidebar_button ("Installed", "computer-symbolic");
            installed_btn.clicked.connect (() => {
                set_sidebar_active (installed_btn);
                current_nav = "installed";
                show_view ("installed");
                gtk_search_entry.text = "";
                back_button.visible = false;
            });
            box.append(installed_btn);

            var updates_btn = make_sidebar_button ("Updates", "software-update-available-symbolic");
            updates_btn.clicked.connect (() => {
                set_sidebar_active (updates_btn);
                current_nav = "updates";
                show_view ("updates");
                gtk_search_entry.text = "";
                back_button.visible = false;
            });
            box.append(updates_btn);

            main_window.set_sidebar (sidebar);
            main_window.set_sidebar_visible (true);

            set_sidebar_active (featured_btn);
        }

        private Button make_sidebar_button (string label, string icon_name) {
            return new Singularity.Widgets.SidebarRow (icon_name, label);
        }

        private void set_sidebar_active (Gtk.Button btn) {
            if (sidebar_active_btn is Singularity.Widgets.SidebarRow) {
                ((Singularity.Widgets.SidebarRow) sidebar_active_btn).set_active (false);
            }
            sidebar_active_btn = btn;
            if (btn is Singularity.Widgets.SidebarRow) {
                ((Singularity.Widgets.SidebarRow) btn).set_active (true);
            }
        }

        // ============================================================
        // Navigation
        // ============================================================

        private void show_view (string view_id) {
            main_stack.visible_child_name = view_id;

            if (view_id == "discover" && !discover_loaded) {
                load_discover ();
            } else if (view_id == "charts" && !charts_loaded) {
                load_charts ();
            } else if (view_id == "recent" && !recent_loaded) {
                load_recent ();
            } else if (view_id == "installed") {
                installed_load_then_discover = false;
                refresh_installed_async ();
            } else if (view_id == "updates") {
                refresh_updates_async ();
            }
        }

        // ============================================================
        // Discover view
        // ============================================================

        private void setup_discover_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            discover_spinner = make_spinner ();
            outer.append (discover_spinner);

            discover_box = new Box (Orientation.VERTICAL, 0);
            discover_box.margin_start  = 12;
            discover_box.margin_end    = 12;
            discover_box.margin_top    = 8;
            discover_box.margin_bottom = 24;

            discover_scroll = new ScrolledWindow ();
            discover_scroll.set_child (discover_box);
            discover_scroll.vexpand = true;
            discover_scroll.visible = false;
            outer.append (discover_scroll);

            main_stack.add_named (outer, "discover");
        }

        private void load_discover () {
            discover_loaded = true;
            discover_spinner.spinning = true;
            discover_spinner.visible  = true;
            discover_scroll.visible   = false;
            clear_box (discover_box);

            var msg = new Soup.Message ("GET",
                "https://flathub.org/api/v2/collection/popular?page=1&per_page=18");
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_discover_response);
        }

        private void on_discover_response (Object? obj, AsyncResult res) {
            try {
                var bytes    = http_session.send_and_read_async.end (res);
                var json_str = (string) bytes.get_data ();
                var parser   = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    show_discover_error (); return;
                }
                var root_obj = root.get_object ();
                if (!root_obj.has_member ("hits")) {
                    show_discover_error (); return;
                }
                populate_discover (root_obj.get_array_member ("hits"));
            } catch (Error e) {
                warning ("Discover error: %s", e.message);
                show_discover_error ();
            }
        }

        private void populate_discover (Json.Array hits) {
            discover_spinner.spinning = false;
            discover_spinner.visible  = false;
            clear_box (discover_box);

            if (hits.get_length () == 0) {
                show_discover_error (); return;
            }

            // Featured hero section - horizontal scroll of banner cards
            discover_box.append (make_section_label ("Editor's Picks"));

            var hero_scroll = new ScrolledWindow ();
            hero_scroll.vscrollbar_policy = PolicyType.NEVER;
            hero_scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            var hero_box = new Box (Orientation.HORIZONTAL, 12);
            hero_box.margin_bottom = 8;
            int hero_count = int.min (3, (int) hits.get_length ());
            for (int i = 0; i < hero_count; i++) {
                var info = parse_app (hits.get_object_element (i));
                var hcard = make_hero_card (info);
                hero_box.append (hcard);
            }
            hero_scroll.set_child (hero_box);
            discover_box.append (hero_scroll);

            // New & Noteworthy - vertical list
            var new_lbl = make_section_label ("New & Noteworthy");
            new_lbl.margin_top = 20;
            discover_box.append (new_lbl);

            int new_end = int.min (hero_count + 8, (int) hits.get_length ());
            for (int i = hero_count; i < new_end; i++) {
                discover_box.append (make_app_card (parse_app (hits.get_object_element (i))));
            }

            // Top Free Apps - vertical list
            if ((int) hits.get_length () > new_end) {
                var top_lbl = make_section_label ("Top Free Apps");
                top_lbl.margin_top = 20;
                discover_box.append (top_lbl);

                int top_end = int.min (new_end + 7, (int) hits.get_length ());
                for (int i = new_end; i < top_end; i++) {
                    discover_box.append (make_app_card (parse_app (hits.get_object_element (i))));
                }
            }

            discover_scroll.visible = true;
        }

        private void show_discover_error () {
            discover_loaded = false;
            discover_spinner.spinning = false;
            discover_spinner.visible  = false;
            clear_box (discover_box);

            var err_box = new Box (Orientation.VERTICAL, 16);
            err_box.halign    = Align.CENTER;
            err_box.valign    = Align.CENTER;
            err_box.vexpand   = true;
            err_box.margin_top = 80;

            var icon = new Image.from_icon_name ("network-error-symbolic");
            icon.pixel_size = 64;
            icon.add_css_class ("dim-label");
            err_box.append (icon);

            var lbl = new Label (_("Could not connect to Flathub"));
            lbl.add_css_class ("title-2");
            err_box.append (lbl);

            var sub = new Label (_("Check your internet connection and try again."));
            sub.add_css_class ("dim-label");
            err_box.append (sub);

            var retry = new Button.with_label (_("Retry"));
            retry.halign = Align.CENTER;
            retry.add_css_class ("suggested-action");
            retry.clicked.connect (on_discover_retry);
            err_box.append (retry);

            discover_box.append (err_box);
            discover_scroll.visible = true;
        }

        private void on_discover_retry () {
            load_discover ();
        }

        // ============================================================
        // Charts view
        // ============================================================

        private void setup_charts_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            charts_spinner = make_spinner ();
            charts_spinner.visible = false;
            outer.append (charts_spinner);

            charts_box = new Box (Orientation.VERTICAL, 0);
            charts_box.margin_start  = 12;
            charts_box.margin_end    = 12;
            charts_box.margin_top    = 8;
            charts_box.margin_bottom = 24;

            charts_scroll = new ScrolledWindow ();
            charts_scroll.set_child (charts_box);
            charts_scroll.vexpand = true;
            outer.append (charts_scroll);

            main_stack.add_named (outer, "charts");
        }

        private void load_charts () {
            charts_loaded = true;
            charts_spinner.visible  = true;
            charts_spinner.spinning = true;
            charts_scroll.visible   = false;
            clear_box (charts_box);

            var msg = new Soup.Message ("GET",
                "https://flathub.org/api/v2/collection/popular?page=1&per_page=30");
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_charts_response);
        }

        private void on_charts_response (Object? obj, AsyncResult res) {
            try {
                var bytes    = http_session.send_and_read_async.end (res);
                var json_str = (string) bytes.get_data ();
                var parser   = new Json.Parser ();
                parser.load_from_data (json_str);
                var root_obj = parser.get_root ().get_object ();

                charts_spinner.spinning = false;
                charts_spinner.visible  = false;

                var hits = root_obj.get_array_member ("hits");
                for (uint i = 0; i < hits.get_length (); i++) {
                    charts_box.append (make_app_card (parse_app (hits.get_object_element (i))));
                }
                charts_scroll.visible = true;
            } catch (Error e) {
                warning ("Charts error: %s", e.message);
                charts_loaded = false;
                charts_spinner.spinning = false;
                charts_spinner.visible  = false;
                charts_scroll.visible   = true;
            }
        }

        // ============================================================
        // Recently Updated view
        // ============================================================

        private void setup_recent_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            recent_spinner = make_spinner ();
            recent_spinner.visible = false;
            outer.append (recent_spinner);

            recent_box = new Box (Orientation.VERTICAL, 0);
            recent_box.margin_start  = 12;
            recent_box.margin_end    = 12;
            recent_box.margin_top    = 8;
            recent_box.margin_bottom = 24;

            recent_scroll = new ScrolledWindow ();
            recent_scroll.set_child (recent_box);
            recent_scroll.vexpand = true;
            recent_scroll.visible = false;
            outer.append (recent_scroll);

            main_stack.add_named (outer, "recent");
        }

        private void load_recent () {
            recent_loaded = true;
            recent_spinner.visible  = true;
            recent_spinner.spinning = true;
            recent_scroll.visible   = false;
            clear_box (recent_box);

            var msg = new Soup.Message ("GET",
                "https://flathub.org/api/v2/collection/recently-updated?page=1&per_page=30");
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_recent_response);
        }

        private void on_recent_response (Object? obj, AsyncResult res) {
            try {
                var bytes    = http_session.send_and_read_async.end (res);
                var json_str = (string) bytes.get_data ();
                var parser   = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();

                recent_spinner.spinning = false;
                recent_spinner.visible  = false;

                Json.Array? hits = null;
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var ro = root.get_object ();
                    if (ro.has_member ("hits")) hits = ro.get_array_member ("hits");
                } else if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                    hits = root.get_array ();
                }

                if (hits != null) {
                    for (uint i = 0; i < hits.get_length (); i++) {
                        recent_box.append (make_app_card (parse_app (hits.get_object_element (i))));
                    }
                }
                recent_scroll.visible = true;
            } catch (Error e) {
                warning ("Recent error: %s", e.message);
                recent_loaded = false;
                recent_spinner.spinning = false;
                recent_spinner.visible  = false;
                recent_scroll.visible   = true;
            }
        }

        // ============================================================
        // Search / category-browse view  (shared)
        // ============================================================

        private void setup_search_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            search_spinner = make_spinner ();
            search_spinner.visible = false;
            outer.append (search_spinner);

            search_status = new Label (_("Search for apps on Flathub"));
            search_status.add_css_class ("dim-label");
            search_status.halign = Align.CENTER;
            search_status.valign = Align.CENTER;
            search_status.vexpand = true;
            outer.append (search_status);

            search_result_box = new Box (Orientation.VERTICAL, 0);
            search_result_box.margin_start  = 12;
            search_result_box.margin_end    = 12;
            search_result_box.margin_top    = 8;
            search_result_box.margin_bottom = 24;

            search_scroll = new ScrolledWindow ();
            search_scroll.set_child (search_result_box);
            search_scroll.vexpand = true;
            search_scroll.visible = false;
            outer.append (search_scroll);

            main_stack.add_named (outer, "search");
        }

        private void show_search_view_loading () {
            search_spinner.visible  = true;
            search_spinner.spinning = true;
            search_status.visible   = false;
            search_scroll.visible   = false;
            clear_box (search_result_box);
        }

        private void do_search (string query) {
            show_search_view_loading ();
            main_stack.visible_child_name = "search";
            back_button.visible = true;

            // Flathub API v2 search requires POST with a JSON body {"query": "..."}
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("query");
            builder.add_string_value (query);
            builder.end_object ();
            var gen = new Json.Generator ();
            gen.set_root (builder.get_root ());
            var body_str = gen.to_data (null);

            var msg = new Soup.Message ("POST", "https://flathub.org/api/v2/search");
            msg.set_request_body_from_bytes ("application/json",
                new GLib.Bytes (body_str.data));
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_search_response);
        }

        private void on_search_response (Object? obj, AsyncResult res) {
            try {
                var bytes    = http_session.send_and_read_async.end (res);
                var json_str = (string) bytes.get_data ();
                var parser   = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();

                search_spinner.spinning = false;
                search_spinner.visible  = false;

                Json.Array? hits = null;
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var ro = root.get_object ();
                    if (ro.has_member ("hits")) {
                        hits = ro.get_array_member ("hits");
                    }
                } else if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                    hits = root.get_array ();
                }

                if (hits == null || hits.get_length () == 0) {
                    search_status.label   = _("No apps found");
                    search_status.visible = true;
                    return;
                }

                for (uint i = 0; i < hits.get_length (); i++) {
                    search_result_box.append (make_app_card (parse_app (hits.get_object_element (i))));
                }
                search_scroll.visible = true;
            } catch (Error e) {
                warning ("Search error: %s", e.message);
                search_spinner.spinning = false;
                search_spinner.visible  = false;
                search_status.label     = _("Could not connect to Flathub");
                search_status.visible   = true;
            }
        }

        // ============================================================
        // Category browse
        // ============================================================

        private void browse_category (string category) {
            show_search_view_loading ();
            main_stack.visible_child_name = "search";

            var url = "https://flathub.org/api/v2/collection/category/" + category + "?page=1&per_page=30";
            var msg = new Soup.Message ("GET", url);
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_search_response);
        }

        // ============================================================
        // Installed view
        // ============================================================

        private void setup_installed_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            installed_status = new Label (_("Loading…"));
            installed_status.add_css_class ("dim-label");
            installed_status.halign = Align.CENTER;
            installed_status.valign = Align.CENTER;
            installed_status.vexpand = true;
            outer.append (installed_status);

            installed_box = new Box (Orientation.VERTICAL, 0);
            installed_box.margin_start  = 24;
            installed_box.margin_end    = 24;
            installed_box.margin_top    = 16;
            installed_box.margin_bottom = 24;

            installed_scroll = new ScrolledWindow ();
            installed_scroll.set_child (installed_box);
            installed_scroll.vexpand = true;
            installed_scroll.visible = false;
            outer.append (installed_scroll);

            main_stack.add_named (outer, "installed");
        }

        private void refresh_installed_async () {
            installed_status.label   = _("Loading installed apps…");
            installed_status.visible = true;
            installed_scroll.visible = false;
            new Thread<bool> ("installed-apps", do_load_installed);
        }

        private bool do_load_installed () {
            string stdout_str = "";
            string stderr_str = "";
            int status = 0;
            try {
                Process.spawn_command_line_sync (
                    "flatpak list --columns=application",
                    out stdout_str, out stderr_str, out status);
            } catch (Error e) {
                warning ("flatpak list error: %s", e.message);
            }

            string[] ids = {};
            foreach (var line in stdout_str.split ("\n")) {
                var trimmed = line.strip ();
                if (trimmed != "") ids += trimmed;
            }
            installed_app_ids = ids;

            Idle.add (on_installed_loaded);
            return true;
        }

        private bool on_installed_loaded () {
            populate_installed_view ();
            if (installed_load_then_discover) {
                installed_load_then_discover = false;
                load_discover ();
            }
            return false;
        }

        private void populate_installed_view () {
            installed_status.visible = false;
            clear_box (installed_box);

            if (installed_app_ids.length == 0) {
                var lbl = new Label (_("No Flatpak apps installed"));
                lbl.add_css_class ("dim-label");
                lbl.halign    = Align.CENTER;
                lbl.margin_top = 80;
                installed_box.append (lbl);
                installed_scroll.visible = true;
                return;
            }

            var list = new ListBox ();
            list.add_css_class ("boxed-list");
            list.selection_mode = SelectionMode.NONE;

            foreach (var app_id in installed_app_ids) {
                if (app_id.strip () == "") continue;
                list.append (make_installed_row (app_id));
            }

            installed_box.append (list);
            installed_scroll.visible = true;
        }

        private ListBoxRow make_installed_row (string app_id) {
            var row  = new ListBoxRow ();
            var hbox = new Box (Orientation.HORIZONTAL, 12);
            hbox.margin_start  = 12;
            hbox.margin_end    = 12;
            hbox.margin_top    = 8;
            hbox.margin_bottom = 8;

            // Try to resolve real name/icon from .desktop file
            string display_name = app_id;
            string? icon_name_resolved = null;
            var desktop_info = new GLib.DesktopAppInfo (app_id + ".desktop");
            if (desktop_info != null) {
                display_name = desktop_info.get_display_name () ?? app_id;
                var gicon = desktop_info.get_icon ();
                if (gicon != null) icon_name_resolved = gicon.to_string ();
            }

            var icon = icon_name_resolved != null
                ? new Image.from_icon_name (icon_name_resolved)
                : new Image.from_icon_name ("application-x-executable-symbolic");
            icon.pixel_size = 48;
            icon.add_css_class ("store-app-icon");
            hbox.append (icon);

            var info_box = new Box (Orientation.VERTICAL, 4);
            info_box.hexpand = true;
            info_box.valign  = Align.CENTER;

            var name_lbl = new Label (display_name);
            name_lbl.xalign    = 0;
            name_lbl.add_css_class ("store-app-name");
            name_lbl.ellipsize = EllipsizeMode.END;
            info_box.append (name_lbl);

            var id_lbl = new Label (app_id);
            id_lbl.xalign = 0;
            id_lbl.add_css_class ("store-app-summary");
            info_box.append (id_lbl);

            hbox.append (info_box);

            var btn_box = new Box (Orientation.HORIZONTAL, 8);
            btn_box.valign = Align.CENTER;

            var open_btn = new Button.with_label (_("Open"));
            open_btn.add_css_class ("flat");
            open_btn.set_data<string> ("app-id", app_id);
            open_btn.clicked.connect (on_open_installed_clicked);
            btn_box.append (open_btn);

            var remove_btn = new Button.with_label (_("Remove"));
            remove_btn.add_css_class ("flat");
            remove_btn.add_css_class ("destructive-action");
            remove_btn.set_data<string> ("app-id", app_id);
            remove_btn.set_data<ListBoxRow> ("row", row);
            remove_btn.clicked.connect (on_remove_installed_clicked);
            btn_box.append (remove_btn);

            hbox.append (btn_box);
            row.set_child (hbox);
            return row;
        }

        private void on_open_installed_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            if (app_id != null) launch_app (app_id);
        }

        private void on_remove_installed_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            var row    = btn.get_data<ListBoxRow> ("row");
            if (app_id == null) return;
            try {
                Process.spawn_command_line_async (
                    "flatpak uninstall -y " + GLib.Shell.quote (app_id));
                if (row != null) row.visible = false;
            } catch (Error e) {
                warning ("Remove error: %s", e.message);
            }
        }

        // ============================================================
        // Updates view
        // ============================================================

        private void setup_updates_view () {
            var outer = new Box (Orientation.VERTICAL, 0);

            updates_status = new Label (_("Checking for updates…"));
            updates_status.add_css_class ("dim-label");
            updates_status.halign = Align.CENTER;
            updates_status.valign = Align.CENTER;
            updates_status.vexpand = true;
            outer.append (updates_status);

            updates_box = new Box (Orientation.VERTICAL, 0);
            updates_box.margin_start  = 24;
            updates_box.margin_end    = 24;
            updates_box.margin_top    = 16;
            updates_box.margin_bottom = 24;

            updates_scroll = new ScrolledWindow ();
            updates_scroll.set_child (updates_box);
            updates_scroll.vexpand = true;
            updates_scroll.visible = false;
            outer.append (updates_scroll);

            main_stack.add_named (outer, "updates");
        }

        private void refresh_updates_async () {
            updates_status.label   = _("Checking for updates…");
            updates_status.visible = true;
            updates_scroll.visible = false;
            new Thread<bool> ("check-updates", do_check_updates);
        }

        private bool do_check_updates () {
            string stdout_str = "";
            string stderr_str = "";
            int status_code   = 0;
            try {
                Process.spawn_command_line_sync (
                    "flatpak remote-ls --updates --columns=application",
                    out stdout_str, out stderr_str, out status_code);
            } catch (Error e) {
                warning ("Updates check error: %s", e.message);
            }

            string[] ids = {};
            foreach (var line in stdout_str.split ("\n")) {
                var trimmed = line.strip ();
                if (trimmed != "") ids += trimmed;
            }
            pending_update_ids = ids;

            Idle.add (on_updates_checked);
            return true;
        }

        private bool on_updates_checked () {
            updates_status.visible = false;
            clear_box (updates_box);

            if (pending_update_ids.length == 0) {
                var lbl = new Label (_("All apps are up to date."));
                lbl.add_css_class ("dim-label");
                lbl.halign    = Align.CENTER;
                lbl.margin_top = 80;
                updates_box.append (lbl);
                updates_scroll.visible = true;
                return false;
            }

            var update_all_btn = new Button.with_label (_("Update All"));
            update_all_btn.add_css_class ("suggested-action");
            update_all_btn.halign      = Align.END;
            update_all_btn.margin_bottom = 12;
            update_all_btn.clicked.connect (on_update_all_clicked);
            updates_box.append (update_all_btn);

            var list = new ListBox ();
            list.add_css_class ("boxed-list");
            list.selection_mode = SelectionMode.NONE;

            foreach (var app_id in pending_update_ids) {
                if (app_id.strip () == "") continue;

                var row  = new ListBoxRow ();
                var hbox = new Box (Orientation.HORIZONTAL, 12);
                hbox.margin_start  = 12;
                hbox.margin_end    = 12;
                hbox.margin_top    = 8;
                hbox.margin_bottom = 8;

                var icon = new Image.from_icon_name ("application-x-executable-symbolic");
                icon.pixel_size = 48;
                icon.add_css_class ("store-app-icon");
                hbox.append (icon);

                var name_lbl = new Label (app_id);
                name_lbl.xalign    = 0;
                name_lbl.add_css_class ("store-app-name");
                name_lbl.hexpand   = true;
                name_lbl.valign    = Align.CENTER;
                name_lbl.ellipsize = EllipsizeMode.END;
                hbox.append (name_lbl);

                var update_btn = new Button.with_label (_("Update"));
                update_btn.add_css_class ("suggested-action");
                update_btn.add_css_class ("flat");
                update_btn.set_data<string> ("app-id", app_id);
                update_btn.clicked.connect (on_update_single_clicked);
                hbox.append (update_btn);

                row.set_child (hbox);
                list.append (row);
            }

            updates_box.append (list);
            updates_scroll.visible = true;
            return false;
        }

        private void on_update_all_clicked () {
            try {
                Process.spawn_command_line_async ("flatpak update -y");
            } catch (Error e) {
                warning ("Update all error: %s", e.message);
            }
        }

        private void on_update_single_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            if (app_id == null) return;
            try {
                Process.spawn_command_line_async (
                    "flatpak update -y " + GLib.Shell.quote (app_id));
                btn.label     = _("Updating…");
                btn.sensitive = false;
            } catch (Error e) {
                warning ("Update error: %s", e.message);
            }
        }

        // ============================================================
        // Detail view
        // ============================================================

        private void setup_detail_view () {
            detail_box = new Box (Orientation.VERTICAL, 0);
            detail_box.margin_start  = 32;
            detail_box.margin_end    = 32;
            detail_box.margin_top    = 32;
            detail_box.margin_bottom = 32;

            install_log_expander = new Expander ("Show Installation Logs");
            install_log_expander.visible = false;
            install_log_expander.margin_top = 16;

            install_log_text = new TextView ();
            install_log_text.editable = false;
            install_log_text.cursor_visible = false;
            install_log_text.add_css_class ("monospace");
            install_log_text.set_size_request (-1, 100);

            var log_scroll = new ScrolledWindow ();
            log_scroll.set_child (install_log_text);
            log_scroll.set_size_request (-1, 100);
            log_scroll.propagate_natural_height = true;
            install_log_expander.set_child (log_scroll);
            detail_scroll = new ScrolledWindow ();
            detail_scroll.set_child (detail_box);
            main_stack.add_named (detail_scroll, "detail");
        }

        private void show_app_detail (string app_id) {
            current_detail_app_id         = app_id;
            main_stack.visible_child_name = "detail";
            back_button.visible           = true;
            clear_box (detail_box);

            var sp = make_spinner ();
            sp.margin_top = 80;
            detail_box.append (sp);

            var url = "https://flathub.org/api/v2/appstream/" +
                      GLib.Uri.escape_string (app_id, null, true);
            var msg = new Soup.Message ("GET", url);
            http_session.send_and_read_async.begin (msg, GLib.Priority.DEFAULT, null,
                on_detail_response);
        }

        private void on_detail_response (Object? obj, AsyncResult res) {
            try {
                var bytes    = http_session.send_and_read_async.end (res);
                var json_str = (string) bytes.get_data ();
                var parser   = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    show_detail_error ("Could not load app details"); return;
                }
                var app_obj = root.get_object ();
                var info    = new AppInfo ();
                info.app_id = obj_str (app_obj, "id");
                if (info.app_id == "") info.app_id = current_detail_app_id;
                info.name   = obj_str (app_obj, "name");
                if (info.name == "") info.name = info.app_id;
                info.summary     = obj_str (app_obj, "summary");
                info.description = obj_str (app_obj, "description");
                info.developer   = obj_str (app_obj, "developer_name");
                info.version_str = app_obj.has_member ("currentReleaseVersion") ?
                    app_obj.get_string_member ("currentReleaseVersion") : null;
                info.icon_url    = app_obj.has_member ("icon") ?
                    app_obj.get_string_member ("icon") : null;
                info.is_installed = is_app_installed (info.app_id);

                // Parse screenshots - prefer the ~624px wide source
                if (app_obj.has_member ("screenshots")) {
                    var shots = app_obj.get_array_member ("screenshots");
                    var urls  = new GLib.GenericArray<string> ();
                    shots.foreach_element ((arr, i, node) => {
                        if (node.get_node_type () != Json.NodeType.OBJECT) return;
                        var shot = node.get_object ();
                        if (!shot.has_member ("sizes")) return;
                        var sizes = shot.get_array_member ("sizes");
                        string? best = null;
                        int best_w = 0;
                        sizes.foreach_element ((sarr, j, snode) => {
                            if (snode.get_node_type () != Json.NodeType.OBJECT) return;
                            var sz = snode.get_object ();
                            int w  = int.parse (obj_str (sz, "width"));
                            string src = obj_str (sz, "src");
                            if (src == "") return;
                            // target ~624px; pick the closest without going below 400
                            if (w >= 400 && (best == null || (w - 624).abs () < (best_w - 624).abs ())) {
                                best   = src;
                                best_w = w;
                            }
                        });
                        if (best != null) urls.add (best);
                    });
                    info.screenshot_urls = urls.data;
                }
                populate_detail (info);
            } catch (Error e) {
                warning ("Detail error: %s", e.message);
                show_detail_error ("Could not load app details: " + e.message);
            }
        }

        private void show_detail_error (string message) {
            clear_box (detail_box);
            var lbl = new Label (message);
            lbl.add_css_class ("dim-label");
            lbl.halign    = Align.CENTER;
            lbl.margin_top = 80;
            detail_box.append (lbl);
        }

        private void populate_detail (AppInfo info) {
            clear_box (detail_box);

            // Header row
            var header = new Box (Orientation.HORIZONTAL, 24);
            header.margin_bottom = 24;

            var icon = new Image.from_icon_name ("application-x-executable-symbolic");
            icon.pixel_size = 128;
            icon.add_css_class ("store-app-icon");
            icon.valign = Align.START;
            header.append (icon);

            var meta = new Box (Orientation.VERTICAL, 8);
            meta.hexpand = true;
            meta.valign  = Align.CENTER;

            var name_lbl = new Label (info.name);
            name_lbl.add_css_class ("title-1");
            name_lbl.xalign = 0;
            meta.append (name_lbl);

            if (info.developer != "") {
                var dev_lbl = new Label (info.developer);
                dev_lbl.add_css_class ("dim-label");
                dev_lbl.xalign = 0;
                meta.append (dev_lbl);
            }

            if (info.summary != "") {
                var sum_lbl = new Label (strip_html (info.summary));
                sum_lbl.xalign         = 0;
                sum_lbl.wrap           = true;
                sum_lbl.max_width_chars = 60;
                meta.append (sum_lbl);
            }

            var action_box = new Box (Orientation.HORIZONTAL, 8);
            action_box.margin_top = 8;

            if (info.is_installed) {
                var open_btn = new Button.with_label (_("Open"));
                open_btn.add_css_class ("suggested-action");
                open_btn.set_data<string> ("app-id", info.app_id);
                open_btn.clicked.connect (on_detail_open_clicked);
                action_box.append (open_btn);

                var remove_btn = new Button.with_label (_("Remove"));
                remove_btn.add_css_class ("destructive-action");
                remove_btn.set_data<string> ("app-id", info.app_id);
                remove_btn.clicked.connect (on_detail_remove_clicked);
                action_box.append (remove_btn);
            } else {
                var install_btn = new Button.with_label (_("Get"));
                install_btn.add_css_class ("suggested-action");
                install_btn.set_data<string> ("app-id", info.app_id);
                install_btn.clicked.connect (on_detail_install_clicked);
                action_box.append (install_btn);
            }
            meta.append (action_box);

            var rating_box = new Box (Orientation.HORIZONTAL, 4);
            rating_box.margin_top = 8;
            rating_box.visible    = false;
            meta.append (rating_box);

            if (info.version_str != null) {
                var ver_lbl = new Label (_("Version ") + info.version_str);
                ver_lbl.add_css_class ("dim-label");
                ver_lbl.add_css_class ("caption");
                ver_lbl.xalign = 0;
                meta.append (ver_lbl);
            }

            header.append (meta);
            detail_box.append (header);

            // Install logs (initially hidden, placed right under header for proximity to buttons)
            install_log_expander.visible = false;
            detail_box.append (install_log_expander);

            var sep = new Separator (Orientation.HORIZONTAL);
            sep.margin_bottom = 16;
            detail_box.append (sep);

            // Screenshot carousel (populated asynchronously below)
            if (info.screenshot_urls.length > 0) {
                var carousel = new Singularity.Widgets.ScreenshotCarousel (info.screenshot_urls);
                carousel.margin_bottom = 20;
                detail_box.append (carousel);
                load_screenshots_async (info.app_id, info.screenshot_urls, carousel);
            }

            if (info.description != null && info.description != "") {
                var desc_lbl = new Label (strip_html (info.description));
                desc_lbl.xalign     = 0;
                desc_lbl.wrap       = true;
                desc_lbl.selectable = true;
                desc_lbl.use_markup = false;
                detail_box.append (desc_lbl);
            }

            if (info.icon_url != null) {
                load_icon_async (icon, info.icon_url);
            }

            // Permissions section (Play Store style)
            var perm_box = new Box (Orientation.VERTICAL, 8);
            perm_box.margin_top = 24;
            detail_box.append (perm_box);
            load_permissions_async (info.app_id, perm_box);

            // Load ODRS ratings and reviews
            load_odrs_data (info.app_id, rating_box, detail_box);
        }

        private void load_permissions_async (string app_id, Box target_box) {
            // Use Flathub Summary API which includes metadata permissions for all apps
            var url = "https://flathub.org/api/v2/summary/%s".printf (app_id);
            var msg = new Soup.Message ("GET", url);
            http_session.send_and_read_async.begin (msg, GLib.Priority.LOW, null, (obj, res) => {
                if (current_detail_app_id != app_id) return;
                try {
                    var bytes = http_session.send_and_read_async.end (res);
                    if (bytes == null || bytes.get_size () == 0) return;
                    var json_str = (string) bytes.get_data ();
                    var parser = new Json.Parser ();
                    parser.load_from_data (json_str);
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
                    var obj2 = root.get_object ();
                    if (!obj2.has_member ("metadata")) return;
                    var meta = obj2.get_object_member ("metadata");
                    if (!meta.has_member ("permissions")) return;
                    var perms_obj = meta.get_object_member ("permissions");

                    var title = new Label (_("Permissions"));
                    title.add_css_class ("title-4");
                    title.xalign = 0;
                    title.margin_top = 24;
                    title.margin_bottom = 8;
                    target_box.append (title);

                    var grid = new Grid ();
                    grid.column_spacing = 12;
                    grid.row_spacing = 8;

                    int row = 0;

                    if (perms_obj.has_member ("shared")) {
                        var shared = perms_obj.get_array_member ("shared");
                        shared.foreach_element ((a, i, node) => {
                            string? icon = null;
                            string? label = null;
                            var val = node.get_string ();
                            if (val == "network") { icon = "network-transmit-receive-symbolic"; label = "Full Network Access"; }
                            else if (val == "ipc") { icon = "system-run-symbolic"; label = "Inter-process Communication"; }

                            if (icon != null) {
                                var p_icon = new Image.from_icon_name (icon);
                                p_icon.pixel_size = 16;
                                p_icon.add_css_class ("dim-label");
                                grid.attach (p_icon, 0, row, 1, 1);
                                var p_lbl = new Label (label);
                                p_lbl.xalign = 0;
                                p_lbl.add_css_class ("caption");
                                grid.attach (p_lbl, 1, row, 1, 1);
                                row++;
                            }
                        });
                    }
                    if (perms_obj.has_member ("sockets")) {
                        var sockets = perms_obj.get_array_member ("sockets");
                        sockets.foreach_element ((a, i, node) => {
                            string? icon = null;
                            string? label = null;
                            var val = node.get_string ();
                            if (val == "wayland" || val == "x11") { icon = "video-display-symbolic"; label = "Display Access"; }
                            else if (val == "pulseaudio") { icon = "audio-volume-high-symbolic"; label = "Audio System Access"; }

                            if (icon != null) {
                                var p_icon = new Image.from_icon_name (icon);
                                p_icon.pixel_size = 16;
                                p_icon.add_css_class ("dim-label");
                                grid.attach (p_icon, 0, row, 1, 1);
                                var p_lbl = new Label (label);
                                p_lbl.xalign = 0;
                                p_lbl.add_css_class ("caption");
                                grid.attach (p_lbl, 1, row, 1, 1);
                                row++;
                            }
                        });
                    }
                    if (perms_obj.has_member ("devices")) {
                        var devices = perms_obj.get_array_member ("devices");
                        devices.foreach_element ((a, i, node) => {
                            if (node.get_string () == "all") {
                                var p_icon = new Image.from_icon_name ("input-mouse-symbolic");
                                p_icon.pixel_size = 16;
                                p_icon.add_css_class ("dim-label");
                                grid.attach (p_icon, 0, row, 1, 1);
                                var p_lbl = new Label (_("All Hardware Devices"));
                                p_lbl.xalign = 0;
                                p_lbl.add_css_class ("caption");
                                grid.attach (p_lbl, 1, row, 1, 1);
                                row++;
                            }
                        });
                    }
                    if (perms_obj.has_member ("filesystems")) {
                        var fs = perms_obj.get_array_member ("filesystems");
                        bool home = false, downloads = false;
                        fs.foreach_element ((a, i, node) => {
                            var val = node.get_string ();
                            if (val == "home") home = true;
                            if (val == "xdg-download") downloads = true;
                        });
                        if (home) {
                            var p_icon = new Image.from_icon_name ("folder-home-symbolic");
                            p_icon.pixel_size = 16;
                            p_icon.add_css_class ("dim-label");
                            grid.attach (p_icon, 0, row, 1, 1);
                            var p_lbl = new Label (_("Access to Home Files"));
                            p_lbl.xalign = 0;
                            p_lbl.add_css_class ("caption");
                            grid.attach (p_lbl, 1, row, 1, 1);
                            row++;
                        } else if (downloads) {
                            var p_icon = new Image.from_icon_name ("folder-download-symbolic");
                            p_icon.pixel_size = 16;
                            p_icon.add_css_class ("dim-label");
                            grid.attach (p_icon, 0, row, 1, 1);
                            var p_lbl = new Label (_("Access to Downloads"));
                            p_lbl.xalign = 0;
                            p_lbl.add_css_class ("caption");
                            grid.attach (p_lbl, 1, row, 1, 1);
                            row++;
                        }
                    }

                    if (row > 0) target_box.append (grid);
                    else target_box.remove (title); // Nothing interesting to show

                } catch (Error e) { warning ("Perms error: %s", e.message); }
            });
        }

        private void load_odrs_data (string app_id, Box rating_box, Box target_box) {
            // Some apps need ID cleaning for ODRS
            string clean_id = app_id;
            if (clean_id.has_suffix(".desktop")) clean_id = clean_id.replace(".desktop", "");

            // 1. Fetch Ratings (Global score)
            var ratings_url = "https://odrs.gnome.org/1.0/reviews/api/ratings/%s".printf (clean_id);
            var ratings_msg = new Soup.Message ("GET", ratings_url);
            http_session.send_and_read_async.begin (ratings_msg, GLib.Priority.LOW, null, (obj, res) => {
                if (current_detail_app_id != app_id) return;
                try {
                    var bytes = http_session.send_and_read_async.end (res);
                    if (bytes == null || bytes.get_size () == 0) {
                        warning ("ODRS ratings: Empty response for %s", clean_id);
                        return;
                    }
                    var json_str = (string) bytes.get_data ();
                    var parser = new Json.Parser ();
                    parser.load_from_data (json_str);
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
                    var obj2 = root.get_object ();

                    int64 total = obj2.has_member ("total") ? obj2.get_int_member ("total") : 0;
                    if (total == 0) {
                        warning ("ODRS ratings: Total is 0 for %s", clean_id);
                        return;
                    }

                    double average = 0;
                    if (obj2.has_member ("star5")) average += 5 * obj2.get_int_member ("star5");
                    if (obj2.has_member ("star4")) average += 4 * obj2.get_int_member ("star4");
                    if (obj2.has_member ("star3")) average += 3 * obj2.get_int_member ("star3");
                    if (obj2.has_member ("star2")) average += 2 * obj2.get_int_member ("star2");
                    if (obj2.has_member ("star1")) average += 1 * obj2.get_int_member ("star1");
                    average = average / total;

                    clear_box (rating_box);
                    for (int s = 0; s < (int)Math.round(average); s++) {
                        var star = new Label ("★");
                        star.add_css_class ("accent-label");
                        rating_box.append (star);
                    }
                    var score_btn = new Button.with_label (_("%.1f (%lld ratings)").printf (average, total));
                    score_btn.add_css_class ("flat");
                    score_btn.add_css_class ("caption");
                    score_btn.clicked.connect (() => {
                        var adj = detail_scroll.get_vadjustment ();
                        adj.set_value (adj.get_upper());
                    });
                    rating_box.append (score_btn);
                    rating_box.visible = true;
                } catch (Error e) {
                    warning ("Ratings error for %s: %s", clean_id, e.message);
                }
            });

            // 2. Fetch Reviews (Individual comments)
            var url = "https://odrs.gnome.org/1.0/reviews/api/fetch";
            var msg = new Soup.Message ("POST", url);
            // ODRS strictly requires a 40-character SHA1 user_hash and en_US-style locale.
            var body = "{\"app_id\":\"%s\",\"locale\":\"en_US\",\"distro\":\"SingularityOS\",\"user_hash\":\"da39a3ee5e6b4b0d3255bfef95601890afd80709\",\"limit\":10,\"version\":\"0\",\"karma\":0}".printf (clean_id);
            msg.set_request_body_from_bytes ("application/json", new GLib.Bytes (body.data));
            http_session.send_and_read_async.begin (msg, GLib.Priority.LOW, null, (obj, res) => {
                if (current_detail_app_id != app_id) return;
                try {
                    var bytes = http_session.send_and_read_async.end (res);
                    if (bytes == null || bytes.get_size () == 0) return;
                    var json_str = (string) bytes.get_data ();
                    var parser = new Json.Parser ();
                    parser.load_from_data (json_str);
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.ARRAY) {
                        warning ("ODRS fetch for %s returned non-array: %s", clean_id, json_str);
                        return;
                    }
                    var arr = root.get_array ();
                    if (arr.get_length () == 0) {
                        warning ("No reviews found for %s", clean_id);
                        return;
                    }

                    var reviews_sep = new Separator (Orientation.HORIZONTAL);
                    reviews_sep.margin_top = 24;
                    reviews_sep.margin_bottom = 12;
                    target_box.append (reviews_sep);

                    var reviews_lbl = new Label (_("Reviews"));
                    reviews_lbl.add_css_class ("title-4");
                    reviews_lbl.xalign = 0;
                    reviews_lbl.margin_bottom = 12;
                    target_box.append (reviews_lbl);

                    arr.foreach_element ((a, i, node) => {
                        var obj2 = node.get_object ();
                        if (obj2 == null) return;
                        string reviewer = obj2.has_member ("user_display") ? obj2.get_string_member ("user_display") : "Anonymous";
                        string summary = obj2.has_member ("summary") ? obj2.get_string_member ("summary") : "";
                        string description = obj2.has_member ("description") ? obj2.get_string_member ("description") : "";
                        int64 rating = obj2.has_member ("rating") ? obj2.get_int_member ("rating") : 0;

                        var review_box = new Box (Orientation.VERTICAL, 6);
                        review_box.add_css_class ("store-review-card");
                        review_box.margin_bottom = 12;

                        var header_row = new Box (Orientation.HORIZONTAL, 8);
                        var reviewer_lbl = new Label (reviewer);
                        reviewer_lbl.add_css_class ("bold");
                        reviewer_lbl.xalign = 0;
                        reviewer_lbl.hexpand = true;
                        header_row.append (reviewer_lbl);

                        int stars = (int) Math.round (rating / 20.0);
                        var stars_str = new StringBuilder ();
                        for (int s = 0; s < stars.clamp (0, 5); s++) stars_str.append ("★");
                        var stars_lbl = new Label (stars_str.str);
                        stars_lbl.add_css_class ("accent-label");
                        header_row.append (stars_lbl);
                        review_box.append (header_row);

                        if (summary != "") {
                            var sum = new Label (summary);
                            sum.xalign = 0;
                            sum.add_css_class ("bold");
                            review_box.append (sum);
                        }
                        if (description != "") {
                            var desc = new Label (strip_html (description));
                            desc.xalign = 0;
                            desc.wrap = true;
                            desc.add_css_class ("dim-label");
                            review_box.append (desc);
                        }
                        target_box.append (review_box);
                    });
                } catch (Error e) {}
            });
        }

        private void on_detail_open_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            if (app_id != null) launch_app (app_id);
        }

        private void on_detail_remove_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            if (app_id == null) return;
            try {
                Process.spawn_command_line_async (
                    "flatpak uninstall -y " + GLib.Shell.quote (app_id));
                btn.label     = _("Removing…");
                btn.sensitive = false;
            } catch (Error e) {
                warning ("Remove error: %s", e.message);
            }
        }

        private void on_detail_install_clicked (Button btn) {
            var app_id = btn.get_data<string> ("app-id");
            if (app_id != null) install_app (app_id, btn);
        }

        // ============================================================
        // Async icon loading
        // ============================================================

        private void load_screenshots_async (string app_id,
                                              string[] urls,
                                              Singularity.Widgets.ScreenshotCarousel carousel) {
            for (int i = 0; i < urls.length; i++) {
                int idx = i;
                var url = urls[i];
                var msg = new Soup.Message ("GET", url);
                http_session.send_and_read_async.begin (msg, GLib.Priority.LOW, null, (obj, res) => {
                    if (current_detail_app_id != app_id) return;
                    try {
                        var bytes  = http_session.send_and_read_async.end (res);
                        var stream = new GLib.MemoryInputStream.from_bytes (bytes);
                        var pixbuf = new Gdk.Pixbuf.from_stream (stream, null);
                        var texture = Gdk.Texture.for_pixbuf (pixbuf);
                        carousel.set_image (idx, texture);
                    } catch (Error e) { /* keep spinner */ }
                });
            }
        }

        private void load_icon_async (Gtk.Image image, string icon_url) {
            image.set_data<string> ("icon-url", icon_url);
            var msg = new Soup.Message ("GET", icon_url);
            http_session.send_and_read_async.begin (msg, GLib.Priority.LOW, null, (obj, res) => {
                try {
                    var bytes  = http_session.send_and_read_async.end (res);
                    var stream = new GLib.MemoryInputStream.from_bytes (bytes);
                    int sz     = image.pixel_size > 0 ? image.pixel_size : 64;
                    var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (stream, sz, sz, true, null);
                    var stored = image.get_data<string> ("icon-url");
                    if (stored != null && stored == icon_url) {
                        image.set_from_pixbuf (pixbuf);
                    }
                } catch (Error e) { /* keep placeholder */ }
            });
        }

        // ============================================================
        // Widget helpers
        // ============================================================

        private Spinner make_spinner () {
            var s = new Spinner ();
            s.spinning = true;
            s.halign   = Align.CENTER;
            s.valign   = Align.CENTER;
            s.vexpand  = true;
            s.set_size_request (48, 48);
            return s;
        }

        private Label make_section_label (string text) {
            var lbl = new Label (text);
            lbl.add_css_class ("store-section-title");
            lbl.xalign      = 0;
            lbl.margin_start = 6;
            return lbl;
        }

        // Featured banner card - larger, horizontal scroll

        private Widget make_hero_card (AppInfo info) {
            var card = new Button ();
            card.add_css_class ("store-hero-card");
            card.add_css_class ("flat");
            card.halign = Align.START;
            card.width_request = 220;

            string captured_id = info.app_id;
            card.clicked.connect (() => {
                if (captured_id != "") show_app_detail (captured_id);
            });

            var vb = new Box (Orientation.VERTICAL, 8);
            vb.valign        = Align.CENTER;
            vb.margin_start  = 4;
            vb.margin_end    = 4;
            vb.margin_top    = 4;
            vb.margin_bottom = 4;

            var icon = new Image.from_icon_name ("application-x-executable-symbolic");
            icon.pixel_size = 72;
            icon.add_css_class ("store-app-icon");
            icon.halign = Align.CENTER;
            vb.append (icon);

            var name_lbl = new Label (info.name);
            name_lbl.add_css_class ("store-app-name");
            name_lbl.xalign    = 0.5f;
            name_lbl.halign    = Align.CENTER;
            name_lbl.ellipsize = EllipsizeMode.END;
            name_lbl.margin_top = 8;
            vb.append (name_lbl);

            if (info.summary != "") {
                var sum_lbl = new Label (strip_html (info.summary));
                sum_lbl.add_css_class ("store-app-summary");
                sum_lbl.xalign         = 0.5f;
                sum_lbl.halign         = Align.CENTER;
                sum_lbl.wrap           = true;
                sum_lbl.lines          = 2;
                sum_lbl.max_width_chars = 22;
                vb.append (sum_lbl);
            }

            card.set_child (vb);

            if (info.icon_url != null) {
                load_icon_async (icon, info.icon_url);
            }
            return card;
        }

        // App list card - horizontal layout: icon | name+summary | Get button

        private Widget make_app_card (AppInfo info) {
            var card = new Box (Orientation.HORIZONTAL, 12);
            card.add_css_class ("store-app-card");
            card.hexpand = true;

            string captured_id        = info.app_id;
            bool   captured_installed = info.is_installed;

            // Click anywhere on the card (except the button), open detail
            var gesture = new GestureClick ();
            gesture.pressed.connect ((n, x, y) => {
                if (captured_id != "") show_app_detail (captured_id);
            });
            card.add_controller (gesture);

            // Icon
            var icon = new Image.from_icon_name ("application-x-executable-symbolic");
            icon.pixel_size = 64;
            icon.add_css_class ("store-app-icon");
            icon.valign = Align.CENTER;
            card.append (icon);

            // Name + developer + summary
            var info_box = new Box (Orientation.VERTICAL, 2);
            info_box.hexpand = true;
            info_box.valign  = Align.CENTER;

            var name_lbl = new Label (info.name);
            name_lbl.add_css_class ("store-app-name");
            name_lbl.xalign    = 0;
            name_lbl.ellipsize = EllipsizeMode.END;
            info_box.append (name_lbl);

            // Developer: use field if present, else extract from app_id
            string developer = info.developer;
            if (developer == "" && info.app_id != "") {
                string[] parts = info.app_id.split (".");
                if (parts.length >= 2) {
                    string raw = parts[1];
                    developer = raw.substring (0, 1).up () + raw.substring (1);
                }
            }
            if (developer != "") {
                var dev_lbl = new Label (developer);
                dev_lbl.add_css_class ("store-app-developer");
                dev_lbl.xalign    = 0;
                dev_lbl.ellipsize = EllipsizeMode.END;
                info_box.append (dev_lbl);
            }

            if (info.summary != "") {
                string clean = strip_html (info.summary);
                var sum_lbl = new Label (clean);
                sum_lbl.add_css_class ("store-app-summary");
                sum_lbl.xalign         = 0;
                sum_lbl.lines          = 2;
                sum_lbl.wrap           = true;
                sum_lbl.ellipsize      = EllipsizeMode.END;
                sum_lbl.max_width_chars = 50;
                info_box.append (sum_lbl);
            }

            card.append (info_box);

            // Install / Open button on far right
            var install_btn = new Button.with_label (captured_installed ? _("Open") : _("Get"));
            install_btn.add_css_class ("store-install-btn");
            if (captured_installed) {
                install_btn.add_css_class ("installed");
            }
            install_btn.valign = Align.CENTER;
            install_btn.clicked.connect (() => {
                if (captured_installed) {
                    launch_app (captured_id);
                } else {
                    install_app (captured_id, install_btn);
                }
            });
            card.append (install_btn);

            if (info.icon_url != null) {
                load_icon_async (icon, info.icon_url);
            }

            return card;
        }

        // ============================================================
        // Flatpak operations
        // ============================================================

        private bool is_app_installed (string app_id) {
            foreach (var id in installed_app_ids) {
                if (id == app_id) return true;
            }
            return false;
        }

        private void install_app (string app_id, Button? btn) {
            if (btn != null) {
                btn.label     = _("Installing…");
                btn.sensitive = false;
            }

            install_log_text.buffer.text = "Starting Flatpak installation for %s...\n".printf(app_id);
            install_log_expander.visible = true;
            install_log_expander.expanded = true; // Auto-expand to show progress

            install_app_with_logs.begin (app_id, btn);
        }

        private async void install_app_with_logs (string app_id, Button? btn) {
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                var proc = launcher.spawnv ({"flatpak", "install", "-y", "flathub", app_id});

                // Read stdout in real-time
                var stdout_stream = new DataInputStream (proc.get_stdout_pipe ());
                string? line;
                while ((line = yield stdout_stream.read_line_async ()) != null) {
                    TextIter iter;
                    install_log_text.buffer.get_end_iter (out iter);
                    install_log_text.buffer.insert (ref iter, line + "\n", -1);

                    // Auto-scroll to bottom
                    var mark = install_log_text.buffer.get_insert ();
                    install_log_text.scroll_to_mark (mark, 0.0, true, 0.5, 1.0);
                }

                yield proc.wait_async ();

                if (btn != null) {
                    btn.label = _("Installed");
                    btn.add_css_class ("installed");
                    btn.sensitive = true;
                }

                // Hide logs on success after a short delay
                GLib.Timeout.add (2000, () => {
                    install_log_expander.visible = false;
                    return GLib.Source.REMOVE;
                });

                // Refresh installed apps list
                do_load_installed ();

            } catch (Error e) {
                warning ("Install error: %s", e.message);
                TextIter iter;
                install_log_text.buffer.get_end_iter (out iter);
                install_log_text.buffer.insert (ref iter, "ERROR: " + e.message + "\n", -1);
                if (btn != null) {
                    btn.label     = _("Get");
                    btn.sensitive = true;
                }
            }
        }

        private void launch_app (string app_id) {
            try {
                Process.spawn_command_line_async (
                    "flatpak run " + GLib.Shell.quote (app_id));
            } catch (Error e) {
                warning ("Launch error: %s", e.message);
            }
        }

        // ============================================================
        // JSON / util helpers
        // ============================================================

        private AppInfo parse_app (Json.Object? app_obj) {
            var info = new AppInfo ();
            if (app_obj == null) return info;
            info.app_id    = obj_str (app_obj, "app_id");
            if (info.app_id == "") info.app_id = obj_str (app_obj, "id");
            info.name      = obj_str (app_obj, "name");
            if (info.name == "") info.name = info.app_id;
            info.summary   = obj_str (app_obj, "summary");
            info.developer = obj_str (app_obj, "developer_name");
            info.icon_url  = app_obj.has_member ("icon") ?
                app_obj.get_string_member ("icon") : null;
            info.is_installed = is_app_installed (info.app_id);
            if (app_obj.has_member ("categories")) {
                var cats_node = app_obj.get_member ("categories");
                if (cats_node != null && cats_node.get_node_type () == Json.NodeType.ARRAY) {
                    var cats = cats_node.get_array ();
                    if (cats.get_length () > 0) {
                        info.category = cats.get_string_element (0);
                    }
                }
            }
            return info;
        }

        private string obj_str (Json.Object obj, string key) {
            if (!obj.has_member (key)) return "";
            var node = obj.get_member (key);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) return "";
            return node.get_string () ?? "";
        }

        private string strip_html (string html) {
            try {
                var regex = new Regex ("<[^>]+>");
                string stripped = regex.replace (html, -1, 0, " ");
                regex = new Regex ("\\s+");
                stripped = regex.replace (stripped.strip (), -1, 0, " ");
                return stripped.strip ();
            } catch {
                return html;
            }
        }

        private void clear_box (Box box) {
            var child = box.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                box.remove (child);
                child = next;
            }
        }

        private void setup_styles () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_data (STORE_CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string STORE_CSS = """
/* Store App */
.store-hero-card {
    border-radius: 16px;
    min-height: 160px;
    min-width: 220px;
    padding: 20px 16px 16px 16px;
    background: linear-gradient(160deg, alpha(@accent_color, 0.25), alpha(@accent_color, 0.08));
    border: 1px solid alpha(@accent_color, 0.15);
    transition: background 0.2s ease, border-color 0.2s ease;
}

.store-hero-card:hover {
    background: linear-gradient(160deg, alpha(@accent_color, 0.35), alpha(@accent_color, 0.12));
    border-color: alpha(@accent_color, 0.25);
}

.store-app-card {
    border-radius: 12px;
    background: alpha(@text_color, 0.06);
    border-bottom: 1px solid alpha(@text_color, 0.05);
    padding: 14px 16px;
    margin: 4px 8px;
    transition: background 0.15s ease;
}

.store-app-card:hover {
    background: alpha(@text_color, 0.10);
}

.store-app-icon {
    border-radius: 14px;
}

.store-install-btn {
    border-radius: 20px;
    padding: 5px 18px;
    background-color: alpha(@accent_color, 0.18);
    color: @accent_color;
    font-weight: 700;
    font-size: 13px;
    min-width: 64px;
}

.store-install-btn:hover {
    background-color: alpha(@accent_color, 0.30);
}

.store-install-btn.installed {
    background-color: alpha(@text_color, 0.10);
    color: @window_fg_color;
}

.store-section-title {
    font-size: 18px;
    font-weight: bold;
    margin: 16px 0 8px 0;
}

.store-sidebar-item {
    border-radius: 8px;
    padding: 8px 12px;
}

.store-sidebar-item:hover {
    background-color: alpha(@text_color, 0.08);
}

.store-sidebar-item.selected {
    background-color: alpha(@accent_color, 0.2);
    color: @accent_color;
}

.store-rating {
    color: @accent_color;
}

/* Store Search */
.store-search,
.store-search-entry {
    background: transparent;
    background-color: transparent;
    border: none;
    box-shadow: none;
    border-radius: 0;
    outline: none;
    min-width: 280px;
}

.store-search:focus,
.store-search-entry:focus {
    background: transparent;
    background-color: transparent;
    border: none;
    box-shadow: none;
    outline: none;
}

/* Override the inner entry/text nodes that inherit dark background */
/* Override inner nodes of .store-search SearchEntry */
.store-search entry,
.store-search text,
.store-search>text {
    background: transparent;
    background-color: transparent;
    background-image: none;
    color: inherit;
}

searchentry.store-search,
searchentry.store-search:focus,
searchentry.store-search:focus-within {
    background: transparent;
    background-color: transparent;
    background-image: none;
    border: none;
    box-shadow: none;
    outline: none;
}

searchentry.store-search text,
searchentry.store-search entry {
    background: transparent;
    background-color: transparent;
    background-image: none;
}

/* Store card typography */
.store-app-name {
    font-weight: 700;
    font-size: 15px;
}

.store-app-developer {
    font-size: 11px;
    opacity: 0.5;
}

.store-app-summary {
    font-size: 12px;
    opacity: 0.65;
}

.store-app-category {
    font-size: 10px;
    border-radius: 8px;
    padding: 2px 8px;
    background: alpha(@text_color, 0.1);
    opacity: 0.7;
}

/* Store Reviews */
.store-review-card {
    background-color: alpha(@text_color, 0.05);
    border-radius: 12px;
    padding: 12px;
    border: 1px solid alpha(@text_color, 0.08);
}
""";
    }
}
