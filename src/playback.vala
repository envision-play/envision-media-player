[Flags]
enum PipelinePlayFlags {
    VIDEO,
    AUDIO,
    SUBTITLES
}


namespace AudioVolume {
    bool linear_to_logarithmic (Binding binding, Value linear, ref Value logarithmic) {
        logarithmic = Math.cbrt((double)linear);
        return true;
    }

    bool logarithmic_to_linear (Binding binding, Value logarithmic, ref Value linear) {
        linear = Math.pow((double)logarithmic, 3);
        return true;
    }
}


public class Playback : Object {
    public File? last_opened_file { get; private set; }
    public string title { get; private set; default = ""; }
    public double volume { get; set; default = 1; }
    public int64 progress { get; private set; default = -1; }
    public int64 duration { get; private set; default = -1; }
    public bool can_play { get; private set; default = false; }

    Binding? volume_binding;

    private Gst.Pipeline? _pipeline;
    public Gst.Pipeline? pipeline {
        get {
            return _pipeline;
        }

        private set {
            if (_pipeline == value) {
                return;
            }

            if (_pipeline != null) {
                volume_binding.unbind();
                try_set_state(Gst.State.NULL);

                var bus = _pipeline.get_bus();
                bus.message["state-changed"].disconnect(pipeline_state_changed_message_cb);
                bus.message["error"].disconnect(pipeline_error_cb);
                bus.message["eos"].disconnect(pipeline_eos_cb);
                bus.remove_signal_watch();
            }

            if (value != null) {
                var bus = value.get_bus();
                bus.add_signal_watch();
                bus.message["eos"].connect(pipeline_eos_cb);
                bus.message["error"].connect(pipeline_error_cb);
                bus.message["state-changed"].connect(pipeline_state_changed_message_cb);

                var binding_flags = BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL;
                volume_binding = value.bind_property("volume", this, "volume", binding_flags,
                                                     AudioVolume.linear_to_logarithmic,
                                                     AudioVolume.logarithmic_to_linear);

                // Disable Subtitles
                PipelinePlayFlags play_flags;
                value.get("flags", out play_flags);
                play_flags &= ~PipelinePlayFlags.SUBTITLES;
                value.set("flags", play_flags);
            }

            _pipeline = value;
        }
    }

    private Gst.State _state = Gst.State.NULL;
    public Gst.State state {
        get {
            return _state;
        }

        private set {
            if (value == _state) {
                return;
            }

            playing = (value == Gst.State.PLAYING);
            _state = value;
        }
    }

    uint timeout_id = 0;

    private bool _playing = false;
    public bool playing {
        get {
            return _playing;
        }

        private set {
            if (value == _playing) {
                return;
            }

            if (value == true) {
                timeout_id = Timeout.add(100, update_progress);
            } else if (timeout_id > 0) {
                if (Source.remove(timeout_id)) {
                    timeout_id = 0;
                }
            }

            _playing = value;
        }
    }

    public bool open_file(File file) {
        stop();

        pipeline = Gst.ElementFactory.make("playbin", null) as Gst.Pipeline;
        if (pipeline == null) {
            critical("Failed to create pipeline!");
            return false;
        }

        pipeline.set("uri", file.get_uri());

        if (!play()) {
            critical("Cannot play!");
            return false;
        }

        last_opened_file = file;
        can_play = true;

        try {
            var info = file.query_info("standard::display-name", FileQueryInfoFlags.NONE);
            title = info.get_display_name();
        } catch (Error err) {
            warning(err.message);
        }

        return true;
    }

    public bool toggle_playing() {
        if (playing) {
            return pause();
        }
        return play();
    }

    public bool play() {
        if (pipeline != null) {
            return try_set_state(Gst.State.PLAYING);
        } else if (last_opened_file != null) {
            return open_file(last_opened_file);
        }
        return false;
    }

    public bool pause() {
        if (pipeline == null) {
            return false;
        }
        return try_set_state(Gst.State.PAUSED);
    }

    public void stop() {
        try_set_state(Gst.State.NULL);
        pipeline = null;
        progress = -1;
        duration = -1;
        title = "";
    }

    bool update_progress() {
        if (duration == -1 ) {
            int64 duration;
            if (pipeline.query_duration(Gst.Format.TIME, out duration)) {
                this.duration = duration;
            }
        }

        int64 progress;
        if (!pipeline.query_position(Gst.Format.TIME, out progress)) {
            return false;
        }

        this.progress = progress;

        return true;
    }

    bool try_set_state(Gst.State new_state) {
        if (state == new_state) {
            return true;
        }

        if (pipeline.set_state(new_state) == Gst.StateChangeReturn.FAILURE) {
            critical(@"Failed to set pipeline state to $(state)!");
            return false;
        }

        state = new_state;
        return true;
    }

    void pipeline_state_changed_message_cb() {
        state = pipeline.current_state;
    }

    void pipeline_error_cb (Gst.Bus bus, Gst.Message msg) {
        Error err;
        string debug_info;

        msg.parse_error(out err, out debug_info);

        warning(@"Error message received from $(msg.src.name): $(err.message)");
        warning(@"Debugging info: $(debug_info)");
    }

    void pipeline_eos_cb () {
        stop();
    }

    ~Playback() {
        stop();
    }
}
