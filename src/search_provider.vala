namespace Singularity.Apps.Store {

    public class StoreSearchProvider : Singularity.SearchProviderService {
        private const int MAX_RESULTS = 5;

        private weak StoreApp app;
        private Soup.Session session;
        private HashTable<string, Json.Object> hits = new HashTable<string, Json.Object> (str_hash, str_equal);

        public StoreSearchProvider (StoreApp app) {
            this.app = app;
            session = new Soup.Session ();
            session.timeout = 2;
        }

        private static string? query_for (string[] terms) {
            if (terms.length < 2) return null;
            string prefix = terms[0].down ();
            if (prefix != "install" && prefix != _("install").down ()) return null;
            string query = string.joinv (" ", terms[1:terms.length]).strip ();
            return query.length > 1 ? query : null;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string? query = query_for (terms);
            if (query == null) return {};

            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("query");
            builder.add_string_value (query);
            builder.end_object ();
            var gen = new Json.Generator ();
            gen.set_root (builder.get_root ());

            var msg = new Soup.Message ("POST", "https://flathub.org/api/v2/search");
            msg.set_request_body_from_bytes ("application/json", new Bytes (gen.to_data (null).data));
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return {};
            var obj = root.get_object ();
            if (!obj.has_member ("hits")) return {};

            string[] ids = {};
            var array = obj.get_array_member ("hits");
            for (uint i = 0; i < array.get_length () && ids.length < MAX_RESULTS; i++) {
                var hit = array.get_object_element (i);
                string id = member (hit, "app_id");
                if (id == "" || id in ids) continue;
                hits[id] = hit;
                ids += id;
            }
            return ids;
        }

        public override async string[] get_subsearch_results (string[] previous, string[] terms,
                                                             Cancellable? cancellable) throws Error {
            return yield get_initial_results (terms, cancellable);
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            int pending = 0;
            SourceFunc callback = get_result_metas.callback;
            foreach (string id in ids) {
                var hit = hits[id];
                if (hit == null || member (hit, "icon") == "" || icon_file (id).query_exists ()) continue;
                pending++;
                fetch_icon.begin (id, member (hit, "icon"), (obj, res) => {
                    fetch_icon.end (res);
                    if (--pending == 0) Idle.add ((owned) callback);
                });
            }
            if (pending > 0) yield;

            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                var hit = hits[id];
                if (hit == null) continue;
                string name = member (hit, "name");
                var meta = new Singularity.SearchResultMeta (id, name != "" ? name : id);
                string summary = member (hit, "summary");
                string developer = member (hit, "developer_name");
                if (summary != "" && developer != "")
                    meta.description = "%s, %s".printf (summary, developer);
                else
                    meta.description = summary != "" ? summary : developer;
                var file = icon_file (id);
                if (file.query_exists ()) meta.icon = new FileIcon (file);
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms,
                                                                                 uint32 timestamp) throws Error {
            app.open_app_page (id);
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            string? query = query_for (terms);
            app.open_search (query ?? string.joinv (" ", terms));
        }

        private static string member (Json.Object obj, string key) {
            if (!obj.has_member (key)) return "";
            var node = obj.get_member (key);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) return "";
            return node.get_string () ?? "";
        }

        private static File icon_file (string id) {
            return File.new_for_path (Path.build_filename (Environment.get_user_cache_dir (),
                "singularity-store", "icons", id + ".png"));
        }

        private async void fetch_icon (string id, string url) {
            try {
                var msg = new Soup.Message ("GET", url);
                var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                if (msg.status_code != 200 || bytes.get_size () == 0) return;
                var file = icon_file (id);
                DirUtils.create_with_parents (file.get_parent ().get_path (), 0700);
                yield file.replace_contents_async (bytes.get_data (), null, false,
                    FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                debug ("Store search icon %s: %s", id, e.message);
            }
        }
    }
}
