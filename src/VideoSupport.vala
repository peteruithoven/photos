/* Copyright 2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public errordomain VideoError {
    FILE,          // there's a problem reading the video container file (doesn't exist, no read
                   // permission, etc.)

    CONTENTS,      // we can read the container file but its contents are indecipherable (no codec,
                   // malformed data, etc.)
}

public class VideoImportParams {
    // IN:
    public File file;
    public ImportID import_id = ImportID();
    public string? md5;
    
    // IN/OUT:
    public Thumbnails? thumbnails;
    
    // OUT:
    public VideoRow row = VideoRow();
    
    public VideoImportParams(File file, ImportID import_id, string? md5,
        Thumbnails? thumbnails = null) {
        this.file = file;
        this.import_id = import_id;
        this.md5 = md5;
        this.thumbnails = thumbnails;
    }
}

public class VideoReader {
    private const double UNKNOWN_CLIP_DURATION = -1.0;
    
    private double clip_duration = UNKNOWN_CLIP_DURATION;
    private Gdk.Pixbuf preview_frame = null;
    private string filepath = null;
    private Gst.Element colorspace = null;

    public VideoReader(string filepath) {
        this.filepath = filepath;
    }
    
    public static string[] get_supported_file_extensions() {
        string[] result = { "avi", "mpg", "mov", "mts", "ogg", "ogv" };
        return result;
    }
    
    public static bool is_supported_video_file(File file) {
        return is_supported_video_filename(file.get_basename());
    }
    
    public static bool is_supported_video_filename(string filename) {
        string name;
        string extension;
        disassemble_filename(filename, out name, out extension);
        
        return is_in_ci_array(extension, get_supported_file_extensions());
    }
    
    public static ImportResult prepare_for_import(VideoImportParams params) {
#if MEASURE_IMPORT
        Timer total_time = new Timer();
#endif
        File file = params.file;
        
        FileInfo info = null;
        try {
            info = file.query_info(DirectoryMonitor.SUPPLIED_ATTRIBUTES,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            return ImportResult.FILE_ERROR;
        }
        
        if (info.get_file_type() != FileType.REGULAR)
            return ImportResult.NOT_A_FILE;
        
        if (!is_supported_video_file(file)) {
            message("Not importing %s: file is marked as a video file but doesn't have a" +
                "supported extension", file.get_path());
            
            return ImportResult.UNSUPPORTED_FORMAT;
        }
        
        TimeVal timestamp;
        info.get_modification_time(out timestamp);
        
        // make sure params has a valid md5
        assert(params.md5 != null);

        time_t exposure_time = 0;
        string title = "";
        
        VideoReader reader = new VideoReader(file.get_path());
        bool is_interpretable = true;
        double clip_duration = 0.0;
        Gdk.Pixbuf? preview_frame = null;
        try {
            clip_duration = reader.read_clip_duration();
            preview_frame = reader.read_preview_frame();
        } catch (VideoError err) {
            if (err is VideoError.FILE) {
                return ImportResult.FILE_ERROR;
            } else if (err is VideoError.CONTENTS) {
                is_interpretable = false;
                preview_frame = Resources.get_noninterpretable_badge_pixbuf();
                clip_duration = 0.0;
            } else {
                error("can't prepare video for import: an unknown kind of video error occurred");
            }
        }
        
        params.row.video_id = VideoID();
        params.row.filepath = file.get_path();
        params.row.filesize = info.get_size();
        params.row.timestamp = timestamp.tv_sec;
        params.row.width = preview_frame.width;
        params.row.height = preview_frame.height;
        params.row.clip_duration = clip_duration;
        params.row.is_interpretable = is_interpretable;
        params.row.exposure_time = exposure_time;
        params.row.import_id = params.import_id;
        params.row.event_id = EventID();
        params.row.md5 = params.md5;
        params.row.time_created = 0;
        params.row.title = title;
        params.row.backlinks = "";
        params.row.time_reimported = 0;
        params.row.flags = 0;

        if (params.thumbnails != null) {
            params.thumbnails = new Thumbnails();
            ThumbnailCache.generate_for_video_frame(params.thumbnails, preview_frame);
        }
        
#if MEASURE_IMPORT
        debug("IMPORT: total time to import video = %lf", total_time.elapsed());
#endif
        return ImportResult.SUCCESS;
    }
    
    private void read_internal() throws VideoError {
        bool does_file_exist = FileUtils.test(filepath, FileTest.EXISTS | FileTest.IS_REGULAR);
        if (!does_file_exist)
            throw new VideoError.FILE("video file '%s' does not exist or is inaccessible".printf(
                filepath));
        
        Gst.Pipeline thumbnail_pipeline = new Gst.Pipeline("thumbnail-pipeline");
        
        Gst.Element thumbnail_source = Gst.ElementFactory.make("filesrc", "source");
        thumbnail_source.set_property("location", filepath);
        
        Gst.Element thumbnail_decode_bin = Gst.ElementFactory.make("decodebin2", "decode-bin");
        
        ThumbnailSink thumbnail_sink = new ThumbnailSink();
        thumbnail_sink.have_thumbnail.connect(on_have_thumbnail);
        
        colorspace = Gst.ElementFactory.make("ffmpegcolorspace", "colorspace");
        
        thumbnail_pipeline.add_many(thumbnail_source, thumbnail_decode_bin, colorspace,
            thumbnail_sink);

        thumbnail_source.link(thumbnail_decode_bin);
        colorspace.link(thumbnail_sink);
        thumbnail_decode_bin.pad_added.connect(on_pad_added);

        // the get_state( ) call is required after the call to set_state( ) to block this
        // thread until the pipeline thread has entered a consistent state
        thumbnail_pipeline.set_state(Gst.State.PLAYING);
        Gst.State from_state;
        Gst.State to_state;
        thumbnail_pipeline.get_state(out from_state, out to_state, 1000000000);

        Gst.Format time_query_format = Gst.Format.TIME;
        int64 video_length = -1;
        thumbnail_pipeline.query_duration(ref time_query_format, out video_length);
        if (video_length != -1)
            clip_duration = ((double) video_length) / 1000000000.0;
        else
            throw new VideoError.CONTENTS("GStreamer couldn't extract clip duration");
        
        thumbnail_pipeline.set_state(Gst.State.NULL);
        
        if (preview_frame == null) {
            clip_duration = UNKNOWN_CLIP_DURATION;
            throw new VideoError.CONTENTS("GStreamer couldn't extract preview frame");
        }
    }
    
    private void on_pad_added(Gst.Pad pad) {
        Gst.Caps c = pad.get_caps();

        if (c.to_string().has_prefix("video")) {
            pad.link(colorspace.get_static_pad("sink"));
        }
    }
    
    private void on_have_thumbnail(Gdk.Pixbuf pixbuf) {
        preview_frame = pixbuf.copy();
    }
    
    public Gdk.Pixbuf read_preview_frame() throws VideoError {
        if (preview_frame == null)
            read_internal();

        return preview_frame;
    }
    
    public double read_clip_duration() throws VideoError {
        if (clip_duration == UNKNOWN_CLIP_DURATION)
            read_internal();

        return clip_duration;
    }
}

// NOTE: this class is adapted from the class of the same name in project marina; see
//       media/src/marina/thumbnailsink.vala
class ThumbnailSink : Gst.BaseSink {
    int width;
    int height;
    
    const string caps_string = """video/x-raw-rgb,bpp = (int) 32, depth = (int) 32,
                                  endianness = (int) BIG_ENDIAN,
                                  blue_mask = (int)  0xFF000000,
                                  green_mask = (int) 0x00FF0000,
                                  red_mask = (int)   0x0000FF00,
                                  width = (int) [ 1, max ],
                                  height = (int) [ 1, max ],
                                  framerate = (fraction) [ 0, max ]""";

    public signal void have_thumbnail(Gdk.Pixbuf b);
    
    class construct {
        Gst.StaticPadTemplate pad;        
        pad.name_template = "sink";
        pad.direction = Gst.PadDirection.SINK;
        pad.presence = Gst.PadPresence.ALWAYS;
        pad.static_caps.str = caps_string;
        
        add_pad_template(pad.get());        
    }
    
    public ThumbnailSink() {
        Object();
        set_sync(false);
    }
    
    public override bool set_caps(Gst.Caps c) {
        if (c.get_size() < 1)
            return false;
            
        Gst.Structure s = c.get_structure(0);
        
        if (!s.get_int("width", out width) ||
            !s.get_int("height", out height))
            return false;
        return true;
    }
    
    void convert_pixbuf_to_rgb(Gdk.Pixbuf buf) {
        uchar* data = buf.get_pixels();
        int limit = buf.get_width() * buf.get_height();
        
        while (limit-- != 0) {
            uchar temp = data[0];
            data[0] = data[2];
            data[2] = temp;
            
            data += 4;
        }
    }
    
    public override Gst.FlowReturn preroll(Gst.Buffer b) {
        Gdk.Pixbuf buf = new Gdk.Pixbuf.from_data(b.data, Gdk.Colorspace.RGB, 
                                                    true, 8, width, height, width * 4, null);
        convert_pixbuf_to_rgb(buf);
               
        have_thumbnail(buf);
        return Gst.FlowReturn.OK;
    }
}

public class Video : VideoSource {
    public const uint64 FLAG_TRASH =    0x0000000000000001;
    public const uint64 FLAG_OFFLINE =  0x0000000000000002;

    private static bool interpreter_state_changed = false;
    private static int current_state = -1;
    private static bool normal_regen_complete = false;
    private static bool offline_regen_complete = false;
    public static VideoSourceCollection global = null;

    private VideoRow backing_row;
    
    public Video(VideoRow row) {
        this.backing_row = row;

        if (((row.flags & FLAG_TRASH) != 0) || ((row.flags & FLAG_OFFLINE) != 0))
            rehydrate_backlinks(global, row.backlinks);
    }

    public static void init() {
        global = new VideoSourceCollection();

        Gee.ArrayList<VideoRow?> all = VideoTable.get_instance().get_all();
        Gee.ArrayList<Video> all_videos = new Gee.ArrayList<Video>();
        Gee.ArrayList<Video> trashed_videos = new Gee.ArrayList<Video>();
        Gee.ArrayList<Video> offline_videos = new Gee.ArrayList<Video>();
        int count = all.size;
        for (int ctr = 0; ctr < count; ctr++) {
            Video video = new Video(all.get(ctr));
            
            if (video.is_trashed())
                trashed_videos.add(video);
            else if (video.is_offline())
                offline_videos.add(video);
            else
                all_videos.add(video);
        }

        global.add_many_to_trash(trashed_videos);
        global.add_many_to_offline(offline_videos);
        global.add_many(all_videos);

        int saved_state = Config.get_instance().get_video_interpreter_state_cookie();
        current_state = (int) Gst.Registry.get_default().get_feature_list_cookie();
        if (saved_state == Config.NO_VIDEO_INTERPRETER_STATE) {
            message("interpreter state cookie not found; assuming all video thumbnails are out of date");
            interpreter_state_changed = true;
        } else if (saved_state != current_state) {
            message("interpreter state has changed; video thumbnails may be out of date");
            interpreter_state_changed = true;
        }
    }

    public static bool has_interpreter_state_changed() {
        return interpreter_state_changed;
    }
    
    public static void notify_normal_thumbs_regenerated() {
        if (normal_regen_complete)
            return;

        message("normal video thumbnail regeneration completed");

        normal_regen_complete = true;
        if (normal_regen_complete && offline_regen_complete)
            save_interpreter_state();
    }

    public static void notify_offline_thumbs_regenerated() {
        if (offline_regen_complete)
            return;

        message("offline video thumbnail regeneration completed");

        offline_regen_complete = true;
        if (normal_regen_complete && offline_regen_complete)
            save_interpreter_state();
    }

    private static void save_interpreter_state() {
        if (interpreter_state_changed) {
            message("saving video interpreter state to configuration system");

            Config.get_instance().set_video_interpreter_state_cookie(current_state);
            interpreter_state_changed = false;
        }
    }

    public static void terminate() {
    }

    protected override void commit_backlinks(SourceCollection? sources, string? backlinks) {        
        try {
            VideoTable.get_instance().update_backlinks(get_video_id(), backlinks);
            lock (backing_row) {
                backing_row.backlinks = backlinks;
            }
        } catch (DatabaseError err) {
            warning("Unable to update link state for %s: %s", to_string(), err.message);
        }
    }

    public static bool is_duplicate(File? file, string? full_md5) {
        assert(file != null || full_md5 != null);
#if !NO_DUPE_DETECTION
        return VideoTable.get_instance().has_duplicate(file, full_md5);
#else
        return false;
#endif
    }
    
    public static ImportResult import_create(VideoImportParams params, out Video video) {
        // add to the database
        try {
            if (VideoTable.get_instance().add(ref params.row).is_invalid())
                return ImportResult.DATABASE_ERROR;
        } catch (DatabaseError err) {
            return ImportResult.DATABASE_ERROR;
        }
        
        // create local object but don't add to global until thumbnails generated
        video = new Video(params.row);

        return ImportResult.SUCCESS;
    }
    
    public static void import_failed(Video video) {
        try {
            VideoTable.get_instance().remove(video.get_video_id());
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
    }

    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return ThumbnailCache.fetch(this, scale);
    }

    public override string get_master_md5() {
        lock (backing_row) {
            return backing_row.md5;
        }
    }

    public override Gdk.Pixbuf? create_thumbnail(int scale) throws Error {
        VideoReader reader = new VideoReader(backing_row.filepath);
        
        try {
            return reader.read_preview_frame();
        } catch (VideoError err) {
            return Resources.get_noninterpretable_badge_pixbuf().copy();
        }
    }
    
    public override string? get_unique_thumbnail_name() {
        return (THUMBNAIL_NAME_PREFIX + "-%016llx".printf(backing_row.video_id.id));
    }
    
    public override PhotoFileFormat get_preferred_thumbnail_format() {
        return PhotoFileFormat.get_system_default_format();
    }
    
    public override string get_name() {
        lock (backing_row) {
            if (!is_string_empty(backing_row.title))
                return backing_row.title;
        }
        return get_basename();
    }

    public override string? get_title() {
        lock (backing_row) {
            return backing_row.title;
        }
    }

    public override void set_title(string? title) {
        lock (backing_row) {
            if (backing_row.title == title)
                return;

            try {
                VideoTable.get_instance().set_title(backing_row.video_id, title);
            } catch (DatabaseError e) {
                AppWindow.database_error(e);
				return;
            }
            // if we didn't short-circuit return in the catch clause above, then the change was
            // successfully committed to the database, so update it in the in-memory row cache
            backing_row.title = title;
        }

        notify_altered(new Alteration("metadata", "name"));
    }

    public override Rating get_rating() {
        lock (backing_row) {
            return backing_row.rating;
        }
    }

    public override void set_rating(Rating rating) {
        lock (backing_row) {
            if ((!rating.is_valid()) || (rating == backing_row.rating))
                return;

            try {            
                VideoTable.get_instance().set_rating(get_video_id(), rating);
            } catch (DatabaseError e) {
	            AppWindow.database_error(e);
				return;
            }
            // if we didn't short-circuit return in the catch clause above, then the change was
            // successfully committed to the database, so update it in the in-memory row cache
            backing_row.rating = rating;
        }

        notify_altered(new Alteration("metadata", "rating"));
    }

    public override void increase_rating() {
        lock (backing_row) {
            set_rating(backing_row.rating.increase());
        }
    }

    public override void decrease_rating() {
        lock (backing_row) {
            set_rating(backing_row.rating.decrease());
        }
    }

    public override bool is_trashed() {
        return is_flag_set(FLAG_TRASH);
    }

    public override bool is_offline() {
        return is_flag_set(FLAG_OFFLINE);
    }

    public override void mark_offline() {
        add_flags(FLAG_OFFLINE);
    }
    
    public override void mark_online() {
        remove_flags(FLAG_OFFLINE);
        if ((!get_is_interpretable()) && has_interpreter_state_changed()) {
            check_is_interpretable();
        }
    }

    public override void trash() {
        add_flags(FLAG_TRASH);
    }
    
    public override void untrash() {
        remove_flags(FLAG_TRASH);
    }

    public string get_basename() {
        lock (backing_row) {
            return Filename.display_basename(backing_row.filepath);
        }
    }

    public override string to_string() {
        lock (backing_row) {
            return "[%s] %s".printf(backing_row.video_id.id.to_string(), backing_row.filepath);
        }
    }
    
    public VideoID get_video_id() {
        lock (backing_row) {
            return backing_row.video_id;
        }
    }
    
    public time_t get_exposure_time() {
        lock (backing_row) {
            return backing_row.exposure_time;
        }
    }
    
    public Dimensions get_frame_dimensions() {
        lock (backing_row) {
            return Dimensions(backing_row.width, backing_row.height);
        }
    }

    public override Dimensions get_dimensions() {
        return get_frame_dimensions();
    }
    
    public uint64 get_filesize() {
        lock (backing_row) {
            return backing_row.filesize;
        }
    }
    
    public string get_filename() {
        lock (backing_row) {
            return backing_row.filepath;
        }
    }
    
    public override File get_file() {
        return File.new_for_path(get_filename());
    }
    
    public override File get_master_file() {
        return get_file();
    }
    
    public void export(File dest_file) throws Error {
        File source_file = File.new_for_path(get_filename());
        source_file.copy(dest_file, FileCopyFlags.OVERWRITE | FileCopyFlags.TARGET_DEFAULT_PERMS,
            null, null);
    }
    
    public double get_clip_duration() {
        lock (backing_row) {
            return backing_row.clip_duration;
        }
    }
    
    public bool get_is_interpretable() {
        lock (backing_row) {
            return backing_row.is_interpretable;
        }
    }

    public void check_is_interpretable() {
        VideoReader backing_file_reader = new VideoReader(get_filename());

        double clip_duration = -1.0;
        Gdk.Pixbuf? preview_frame = null;

        try {
            clip_duration = backing_file_reader.read_clip_duration();
            preview_frame = backing_file_reader.read_preview_frame();
        } catch (VideoError e) {
            // if we catch an error on an interpretable video here, then this video was
            // interpretable in the past but has now become non-interpretable (e.g. its
            // codec was removed from the users system).
            if (get_is_interpretable()) {
                lock (backing_row) {
                    backing_row.is_interpretable = false;
			    }

			    try {
                    VideoTable.get_instance().update_is_interpretable(get_video_id(), false);
                } catch (DatabaseError e) {
                    AppWindow.database_error(e);
                }
            }
            return;
        }

        if (get_is_interpretable())
            return;

        debug("video %s has become interpretable", get_file().get_basename());

        try {
            ThumbnailCache.replace(this, ThumbnailCache.Size.BIG, preview_frame);
            ThumbnailCache.replace(this, ThumbnailCache.Size.MEDIUM, preview_frame);
        } catch (Error e) {
            critical("video has become interpretable but couldn't replace cached thumbnails");
        }

        lock (backing_row) {
            backing_row.is_interpretable = true;
            backing_row.clip_duration = clip_duration;
        }

        try {
            VideoTable.get_instance().update_is_interpretable(get_video_id(), true);
        } catch (DatabaseError e) {
            AppWindow.database_error(e);
        }
        
        notify_thumbnail_altered();
    }
    
    public override void destroy() {
        VideoID video_id = get_video_id();

        ThumbnailCache.remove(this);
        
        try {
            VideoTable.get_instance().remove(video_id);
        } catch (DatabaseError err) {
            error("failed to remove video %s from video table", to_string());
        }
        
        base.destroy();
    }

    protected override bool internal_delete_backing() throws Error {
        base.internal_delete_backing();
        
        delete_original_file();
        
        return true;
    }
    
    public uint64 add_flags(uint64 flags_to_add) {
        uint64 new_flags = 0;
        
        lock (backing_row) {
            new_flags = internal_add_flags(backing_row.flags, flags_to_add);

            if (backing_row.flags == new_flags)
                return backing_row.flags;

            try {
                VideoTable.get_instance().set_flags(get_video_id(), new_flags);
            } catch (DatabaseError e) {
                AppWindow.database_error(e);
                return backing_row.flags;
            }

            backing_row.flags = new_flags;
        }
        
        notify_altered(new Alteration("metadata", "flags"));
        
        return backing_row.flags;
    }
    
    public uint64 remove_flags(uint64 flags_to_remove) {
        uint64 new_flags = 0;
        
        lock (backing_row) {
            new_flags = internal_remove_flags(backing_row.flags, flags_to_remove);

            if (backing_row.flags == new_flags)
                return backing_row.flags;

            try {
                VideoTable.get_instance().set_flags(get_video_id(), new_flags);
            } catch (DatabaseError e) {
                AppWindow.database_error(e);
                return backing_row.flags;
            }

            backing_row.flags = new_flags;
        }
        
        notify_altered(new Alteration("metadata", "flags"));
        
        return backing_row.flags;
    }
    
    public bool is_flag_set(uint64 flag) {
        lock (backing_row) {
            return internal_is_flag_set(backing_row.flags, flag);
        }
    }
    
    public override void set_master_file(File file) {
        // TODO: implement master update for videos
    }
}

public class VideoSourceCollection : MediaSourceCollection {
    private Gee.HashMap<File, Video> file_dictionary = new Gee.HashMap<File, Video>(
        file_hash, file_equal);

    public VideoSourceCollection() {
        base("VideoSourceCollection", get_video_key);

        internal_get_trashcan().contents_altered.connect(on_trashcan_contents_altered);
        internal_get_offline_bin().contents_altered.connect(on_offline_contents_altered);
    }
    
    protected override MediaSourceHoldingTank internal_create_trashcan() {
        return new MediaSourceHoldingTank(this, is_video_trashed, get_video_key);
    }

    protected override MediaSourceHoldingTank internal_create_offline_bin() {
        return new MediaSourceHoldingTank(this, is_video_offline, get_video_key);
    }

    private void on_trashcan_contents_altered(Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        trashcan_contents_altered((Gee.Collection<Video>?) added,
            (Gee.Collection<Video>?) removed);
    }

    private void on_offline_contents_altered(Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        stdout.printf("> VideoSourceCollection.on_offline_contents_altered( )\n");
        offline_contents_altered((Gee.Collection<Video>?) added,
            (Gee.Collection<Video>?) removed);
    }

    protected override void notify_contents_altered(Gee.Iterable<DataObject>? added,
        Gee.Iterable<DataObject>? removed) {
        if (added != null) {
            foreach (DataObject object in added) {
                Video video = (Video) object;
                file_dictionary.set(video.get_file(), video);                              
            }
        }
        
        if (removed != null) {
            foreach (DataObject object in removed) {
                Video video = (Video) object;
                
                bool is_removed = file_dictionary.unset(video.get_master_file());
                assert(is_removed);
            }
        }
        
        base.notify_contents_altered(added, removed);
    }
    
    public static int64 get_video_key(DataSource source) {
        Video video = (Video) source;
        VideoID video_id = video.get_video_id();
        
        return video_id.id;
    }

    public Video? get_by_file(File file) {
        Video? video = file_dictionary.get(file);

        if (video != null)
            return video;
        
        video = (Video?) internal_get_trashcan().fetch_by_master_file(file);
        if (video != null)
            return video;
        
        video = (Video?) internal_get_offline_bin().fetch_by_master_file(file);
        if (video != null) {
            return video;
        }
        
        return null;
    }

    public static bool is_video_trashed(DataSource source) {
        return ((Video) source).is_trashed();
    }
    
    public static bool is_video_offline(DataSource source) {
        return ((Video) source).is_offline();
    }
    
    public Video fetch(VideoID video_id) {
        return (Video) fetch_by_key(video_id.id);
    }
}