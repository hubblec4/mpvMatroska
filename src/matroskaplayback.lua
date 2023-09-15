-- Matroska Playback
-- a library to handle Matoska features for playback with mpv
-- written by hubblec4

local mk = require "matroska"
local mkp = require "matroskaparser"
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"


-- constants -------------------------------------------------------------------
local MK_FEATURE = {
    hard_linking            =  1, -- a special system to link files virtually to a single seamless timeline
    basic_chapters          =  2, -- chapters with only a start time
    nested_chapters         =  3, -- chapters within chapters
    ordered_chapters        =  4, -- chapters uses start and end time and are played in the given order of the chapters
    nested_ordered_chapters =  5, -- a combination of nested_ and ordered_ chapters - not fully implemented in the specs
    linked_chapters         =  6, -- same as "ordered_chapters" and additional is the content linked to other files
    linked_editions         =  7, -- same as "linked chapters" but an entire edition is linked to play, a duration of this chapter is ignored
    linked_chapters_file    =  8, -- a file without Tracks, only linked chapters are used
    multiple_editions       = 17, -- more than one edition is present
    multiple_edition_names  = 55, -- there is more than one edition name
    multiple_chapter_names  = 56, -- there is more than one chapter name
    native_menu             = 98, -- Matroska Native Menu -> ChapterProcessCodecID = 0
    dvd_menu                = 99, -- Matroska DVD Menu -> ChapterProcessCodecID = 1
    -- other features later
}


-- gets the directory section of the given path
local function get_directory(path)
    return path:match("^(.+[/\\])[^/\\]+[/\\]?$") or ""
end

-- gets the file name of the given path
local function get_filename(path)
    return path:match("^.+[/\\](.+)$") or path
end



-- -----------------------------------------------------------------------------
-- Internal Edition Class ------------------------------------------------------
-- -----------------------------------------------------------------------------

local Internal_Edition = {
    edl_path = "",
    current_lang = "",
    current_name = "",
    duration = 0,
    ordered = false, -- edition use ordered chapters?
}

-- constructor
function Internal_Edition:new()
    local elem = {}
    setmetatable(elem, self)
    self.__index = self
    elem.chapter_timeline = {} -- array, is a linear chapter list of all used chapters, currently exluded disabled chapters
    return elem
end

-- add_chapter_segment
function Internal_Edition:add_chapter_segment(chp_ref, file_path, time_marker, level, hidden)
    local c_segment = {
        file_path = file_path, -- file path is needed to create the EDL path
        timeline_marker = time_marker, -- float with seconds, this is also a new virtual start time when the referenced chapter is played
        level = level, -- nested level of the chapter
        current_lang = "_nil_", -- init with an invalid language code
        current_name = "",
        Chapter = chp_ref, -- a chapter reference
        -- visible: boolean, this flag overrides the internal ChapterFlagHidden
        -- this can happen when linked-Editions are used and the linked Edition is hidden
        visible = not hidden,
        -- virtual: boolean, such a chapter is used to link a file without chapters
        -- or for Hard-Linking to skip ordered Editions in the chain
        -- or when a first chapter's start time of a non-ordered Edition is not 0
        virtual = false,
        
    }
    table.insert(self.chapter_timeline, c_segment)
    return #self.chapter_timeline
end

-- add_virtual_segment
function Internal_Edition:add_virtual_segment(file_path, time_marker, level, chap_start, chap_end)
    if chap_start == nil then chap_start = 0 end -- check start time

    -- create a virtual chapter and set the times
    local vc = mk.chapters.ChapterAtom:new()
    -- set start time
    vc:get_child(mk.chapters.ChapterTimeStart).value = chap_start
    -- end time, this vaule is not always there (non-ordered editions)
    if chap_end then
        local et = mk.chapters.ChapterTimeEnd:new()
        et.value = chap_end
        table.insert(vc.value, et)
    end

    local idx = self:add_chapter_segment(vc, file_path, time_marker, level, true)
    self.chapter_timeline[idx].virtual = true
    return idx
end

-- add_chap_endtime: a method to set a chapter end time of non-ordered editions
-- with ordered chapters it is everything easy to handle
function Internal_Edition:add_chap_endtime(idx, time)
    -- check if a end time element is already there

    local et = self.chapter_timeline[idx].Chapter:find_child(mk.chapters.ChapterTimeEnd)
    -- end time is present, change the value to new time
    if et then
        et.value = time
        return
    end
    
    -- create new end time element
    et = mk.chapters.ChapterTimeEnd:new()
    et.value = time
    table.insert(self.chapter_timeline[idx].Chapter.value, et)
end

-- get_mpv_chapter_list()
function Internal_Edition:get_mpv_chapter_list(langs)
    -- langs: array with language codes, when nil the first name is used
    if langs == nil then langs = {""} end -- no language code -> first name
    local mpvlist = {} -- mpv chapter list
    local c_name

    -- loop over chapter items
    for _, chp_item in ipairs(self.chapter_timeline) do
        -- chapters must be visible, check item.visible and chapter hidden flag
        if chp_item.visible and not chp_item.Chapter:is_hidden() then
            c_name = ""

            -- find chapter name
            for _, lng in ipairs(langs) do
                -- check lng, nothing todo if the current_lang match
                if lng == chp_item.current_lang then break end

                c_name = chp_item.Chapter:get_name(lng, false, true)

                -- name found
                if c_name ~= "" then
                    chp_item.current_name = c_name
                    chp_item.current_lang = lng -- set new language
                    break
                end
            end

            -- no new name found and current_name is empty
            if c_name == "" and chp_item.current_name == "" then
                c_name = chp_item.Chapter:get_name("") -- get first chapter name
                -- check again, name could be empty -> no chapter Display or a really empty name
                if c_name == "" then c_name = " " end -- use a space for the name
                chp_item.current_name = c_name
                chp_item.current_lang = ""
            end

            -- process nested level
            if chp_item.level > 0 then
                c_name = " "
                for i = 1, chp_item.level do
                    c_name = c_name .. "+"
                end
                c_name = c_name .. " " .. chp_item.current_name
            else
                c_name = chp_item.current_name
            end

            -- add chapter to the mpvlist
            table.insert(mpvlist, {time = chp_item.timeline_marker / 1000000000, title = c_name})
        end
    end

    return mpvlist
end

-- get_main_filepath: returns the file path from the first chapter segment
function Internal_Edition:get_main_filepath()
    return self.chapter_timeline[1].file_path
end

-- create_edl_path
function Internal_Edition:create_edl_path()
    -- non-ordered edition
    if not self.ordered then
        local filepath = self.chapter_timeline[1].file_path -- file path from frist chapter segment
        self.edl_path = ("edl://!no_chapters;%%%d%%%s;"):format(filepath:len(), filepath)
        return
    end

    -- all chapters should now have ever an end time
    local start_time = 0
    local prev_endtime = 0
    local curr_endtime
    local curr_path = ""
    self.edl_path = "edl://!no_chapters;" -- init edl path

    -- loop over chapter items
    for _, chp_item in ipairs(self.chapter_timeline) do
        -- start time
        local curr_starttime = chp_item.Chapter:get_child(mk.chapters.ChapterTimeStart).value
        -- end time
        curr_endtime = chp_item.Chapter:find_child(mk.chapters.ChapterTimeEnd).value

        -- new path, a new file segment or different times
        if chp_item.file_path ~= curr_path or prev_endtime ~= curr_starttime then

            if prev_endtime > start_time then
                self.edl_path = self.edl_path .. ("%%%d%%%s,%f,%f;"):format(curr_path:len(),
                curr_path, start_time / 1000000000, (prev_endtime - start_time) / 1000000000)
            end

            -- new times
            start_time = curr_starttime
            prev_endtime = curr_endtime
            -- new file path
            if chp_item.file_path ~= curr_path then
                curr_path = chp_item.file_path -- set new current path
            end

        else -- same file path and sequential times
            prev_endtime = curr_endtime
        end

    end

    -- last chapter
    if curr_endtime > start_time then
        self.edl_path = self.edl_path .. ("%%%d%%%s,%f,%f;"):format(curr_path:len(),
        curr_path, start_time / 1000000000, (curr_endtime - start_time) / 1000000000)
    end
end


-- -----------------------------------------------------------------------------
-- Matroska Playback class -----------------------------------------------------
-- -----------------------------------------------------------------------------

local Mk_Playback = {
    -- init_file: a parsed first file
    init_file = nil,

    -- init_dir: directory where the init_file is located
    init_dir = "",

    -- mk_files: a list of parsed files which are needed for playback
    mk_files = {},

    -- temp_files: a list of parsed files
    temp_files = {},

    -- used_features: a list of used Matroska features
    used_features = {},

    -- edl_path: a string with a special path system for mpv
    edl_path = "",

    -- mpv_current_vid: mpv number for video streams, start with 1, 0 = not used
    mpv_current_vid = 0,

    -- mpv_current_aid: mpv number for audio streams, start with 1, 0 = not used
    mpv_current_aid = 0,

    -- mpv_current_sid: mpv number for subtitle streams, start with 1, 0 = not used
    mpv_current_sid = 0,

    -- available_chapters_langs: array[lng = true]
    available_chapters_langs = {},

    -- current_edition_idx: integer, 1-based
    current_edition_idx = 0,

    -- internal_editions: array, a list of edition items with useful info
    internal_editions = {},

    -- edition_is_changing: boolean
    edition_is_changing = false,
}

-- constructor
function Mk_Playback:new(path)
    local elem = {}
    setmetatable(elem, self)
    self.__index = self
    elem.init_file = nil
    elem.mk_files = {}
    elem.temp_files = {}
    elem.used_features = {}
    elem.available_chapters_langs = {}
    elem.internal_editions = {}
    elem:_scan(path)
    return elem
end

-- close: clean some var's
function Mk_Playback:close()
    if self.init_file then self.init_file:close() end
    self:_close_files()
end

-- current_edition: returns the current used internal edition
function Mk_Playback:current_edition()
    if self.current_edition_idx == 0 then return nil end
    return self.internal_editions[self.current_edition_idx]
end

-- get_mpv_chapters: returns the mpv chapters list and sets the edition names
-- @param init: boolean, is used for initialization reason
-- @param pref_subs: boolean, is used for subtitle change to use this language first
function Mk_Playback:get_mpv_chapters(init, pref_subs)
    local file, trk, lng
    local langs = {}

    file = self:_get_main_file(true) -- get main file for tracks
    if file then
        -- audio language
        if self.mpv_current_aid > 0 then
            trk = file:get_audio(self.mpv_current_aid)
            if trk then
                lng = trk:get_language()
                if self.available_chapters_langs[lng] then
                    table.insert(langs, lng)
                end
            end
        end
    
        -- subtitle language
        if self.mpv_current_sid > 0 then
            trk = file:get_subtitle(self.mpv_current_sid)
            if trk then
                lng = trk:get_language()
                if self.available_chapters_langs[lng] then
                    -- check pref_subs
                    if pref_subs then
                        table.insert(langs, 1, lng) -- add in first positon
                    else
                        table.insert(langs, lng)
                    end
                end
            end
        end
    end

    -- empty langs list
    if #langs == 0 then
        -- without a language it makes no sense to create the chapters list
        -- it will be the same as current used
        
        -- init is true
        if init then
            langs = nil -- uses nil, this will be change to an empty language -> first chapter name

        else -- init is false/nil
            return nil -- nil signals there is no change necessary of the current chapter list
        end
    end

    -- set edition names
    if init or self.used_features[MK_FEATURE.multiple_edition_names] then
        self:_set_edition_names(langs)
    end

    -- get the mpv chapter list
    if init or self.used_features[MK_FEATURE.multiple_chapter_names] then
        return self:current_edition():get_mpv_chapter_list(langs)

    else return nil
    end
end


-- edition_changing: returns boolean, a method to change the edition
function Mk_Playback:edition_changing(new_idx)
    if new_idx == nil or new_idx == self.current_edition_idx or new_idx > #self.internal_editions
    or not self.used_features[MK_FEATURE.multiple_editions] then return false end

    -- new_idx: integer, 0 means toggle, all other values means the index
    if new_idx == 0 then
        -- toggle editions
        if self.current_edition_idx == #self.internal_editions then -- is already last edition
            self.current_edition_idx = 1 -- set to first edition
        else
            self.current_edition_idx = self.current_edition_idx + 1 -- next index
        end

    else
        self.current_edition_idx = new_idx -- set new index
    end

    -- set active edl_path
    self.edl_path = self.internal_editions[self.current_edition_idx].edl_path

    self.edition_is_changing = true -- changing edition is now true

    return true
    
    --TODO: for later: check switching Angle-Editions
    -- -> Bluray or DVD Angle Movies all Editions have the same duration. after a change restore the position
end


-- video_rotation: a method to rotate automatically the current video
function Mk_Playback:video_rotation()
    if self.mpv_current_vid == 0 then return end
    local mk_file = self:_get_main_file(true)
    if not mk_file then return end

    -- check rotation settings
    local rotate, native = mk_file:get_video_rotation(self.mpv_current_vid)

    -- check native: a native rotate vaule is a float from -180.0 to 180.0
    if native then
        -- first we need an integer, and second the negative values must be transformed
        rotate = math.floor(rotate)

        -- check negative numbers
        if rotate < 0 then
            rotate = rotate + 360
        end
    end

    -- send the mpv rotate command
    if mp.get_property_number("video-rotate") ~= rotate then
		mp.set_property_number("video-rotate", rotate)
	end
end

-- mpv events ------------------------------------------------------------------

-- mpv_on_video_change: event when in mpv the video track is changed
function Mk_Playback:mpv_on_video_change(new_id)
	-- no video selected
    if new_id == nil then
        self.mpv_current_vid = 0
        return
    end
    -- same video id
	if new_id == self.mpv_current_vid then return end
	
	self.mpv_current_vid = new_id -- set new video id

    -- check video rotation
    self:video_rotation()
end

-- mpv_on_audio_change: event when in mpv the audio track is changed
function Mk_Playback:mpv_on_audio_change(new_id)
	-- no audio selected
    if new_id == nil then
        self.mpv_current_aid = 0
        return
    end
    -- same audio id
	if new_id == self.mpv_current_aid then return end
	
	self.mpv_current_aid = new_id -- set new audio id

    -- check and set multiple names
    self:_change_edition_chapter_names()
end

-- mpv_on_subtitle_change: event when in mpv the subtitle track is changed
function Mk_Playback:mpv_on_subtitle_change(new_id)
	-- no subtitle selected
    if new_id == nil then
        self.mpv_current_sid = 0
        return
    end
    -- same subtitle id
	if new_id == self.mpv_current_sid then return end
	
	self.mpv_current_sid = new_id -- set new subtitle id

    -- check and set multiple names
    self:_change_edition_chapter_names(true)
end



-- mpv_set_media_title: a method to change the media title in the OSC and mpv window
function Mk_Playback:mpv_set_media_title()
	local title = get_filename(self:_get_main_file().path) .. " {" .. self:current_edition().current_name .. "}"
	mp.set_property("force-media-title", title)
end



-- private section -------------------------------------------------------------

-- close_files: a method to clean temp_files and mk_files
function Mk_Playback:_close_files(only_temps)
    -- close temp_files
    for _, mk_file in ipairs(self.temp_files) do
        mk_file:close()
    end
    self.temp_files = {}
    -- exit if only temp_file
    if only_temps then return end

    -- close mk_files
    for _, mk_file in ipairs(self.mk_files) do
        if mk_file.seg_uuid ~= self.init_file.seg_uuid then
            mk_file:close()
        end
    end
    self.mk_files = {}
end

-- scan (private): scan the file and prepare all used Matroska features
function Mk_Playback:_scan(path)
    self.init_dir = get_directory(path)

    self.init_file = mkp.Matroska_Parser:new(path)
    if not self.init_file.is_valid then
        return
    end

    self:_check_hard_linking()
    self:_analyze_chapters()
    self:_build_timelines()
end

-- _get_main_file: returns the current main file
function Mk_Playback:_get_main_file(for_tracks)
    -- for_tracks(boolean): not always are the tracks and the chapters in the same main file
    -- Hard-Linking: always the first file of mk_files
    if self.used_features[MK_FEATURE.hard_linking] then
        return self.mk_files[1]
    end

    -- linked-chapters files, init_file has only Chapters, no Tracks
    -- the main file depends on the chapers structure and can be any file in mk_files
    if for_tracks and self.used_features[MK_FEATURE.linked_chapters_file] then
        if self.current_edition_idx > 0 then
            local main_path = self.internal_editions[self.current_edition_idx]:get_main_filepath()
            for _, file in ipairs(self.mk_files) do
                if file.path == main_path then
                    return file
                end
            end
        end
    end

    -- no specials
    return self.init_file
end

-- _analyze_chapters (private): analyze the chapters structure
function Mk_Playback:_analyze_chapters()
    local mk_file = self:_get_main_file()
    self.available_chapters_langs = {}
    if mk_file == nil or mk_file.Chapters == nil then
        self.current_edition_idx = 0
        return
    end

    local edition, e, chap, c, is_ordered, display, d, lng, l, tag

    -- check linked-chapers-file
    if mk_file.Tracks == nil then
        self.used_features[MK_FEATURE.linked_chapters_file] = true
    end

    -- set default edition index
    edition, self.current_edition_idx = mk_file.Chapters:get_default_edition()

    -- check multiple editions, try to find a second edition
    if mk_file.Chapters:get_edition(2)  then
        self.used_features[MK_FEATURE.multiple_editions] = true
    end

    -- process chapter
    local function process_chapter(chp, level)
        -- check linked-editions
        if not self.used_features[MK_FEATURE.linked_editions] then
            if chp:find_child(mk.chapters.ChapterSegmentEditionUID) then
                self.used_features[MK_FEATURE.linked_editions] = true
            end
        end

        -- check linked-chapters
        if not self.used_features[MK_FEATURE.linked_chapters] then
            if chp:find_child(mk.chapters.ChapterSegmentUUID) then
                self.used_features[MK_FEATURE.linked_chapters] = true
            end
        end

        -- check ChapProcess elements for menu features
        local c_process, cp = chp:find_child(mk.chapters.ChapProcess)
        while c_process do
            if not self.used_features[MK_FEATURE.native_menu] then
                if c_process:get_child(mk.chapters.ChapProcessCodecID).value == 0 then
                    self.used_features[MK_FEATURE.native_menu] = true
                end
            end

            if not self.used_features[MK_FEATURE.dvd_menu] then
                if c_process:get_child(mk.chapters.ChapProcessCodecID).value == 1 then
                    self.used_features[MK_FEATURE.dvd_menu] = true
                end
            end
            
            c_process, cp = chp:find_next_child(cp)
        end

        -- loop ChapterDisplays
        display, d = chp:find_child(mk.chapters.ChapterDisplay)
        while display do
            -- loop ChapLanguage
            lng, l = display:find_child(mk.chapters.ChapLanguage)
            while lng do
                self.available_chapters_langs[lng.value] = true -- save language
                lng, l = display:find_next_child(l)
            end
            
            -- loop ChapLanguageBCP47
            lng, l = display:find_child(mk.chapters.ChapLanguageBCP47)
            while lng do
                self.available_chapters_langs[lng.value] = true -- save language
                lng, l = display:find_next_child(l)
            end

            display, d = chp:find_next_child(d)
            -- check multiple chapter names
            if not self.used_features[MK_FEATURE.multiple_chapter_names] and display then
                self.used_features[MK_FEATURE.multiple_chapter_names] = true
            end
        end

        -- Hint: for the moment there is no search in the Tags

        -- check nested chapters
        if level > 8 then return end
        local nchap, nc = chp:find_child(mk.chapters.ChapterAtom)
        if nchap and level == 0 then -- check only at first level
            if is_ordered then
                self.used_features[MK_FEATURE.nested_ordered_chapters] = true
            else
                self.used_features[MK_FEATURE.nested_chapters] = true
            end
        end
        -- loop nested chapters
        while nchap do
            process_chapter(nchap, level + 1)
            nchap, nc = chp:find_next_child(nc)
        end
    end

    -- loop editions
    edition, e = mk_file.Chapters:find_child(mk.chapters.EditionEntry)
    while edition do
        is_ordered = false

        chap, c = edition:find_child(mk.chapters.ChapterAtom)
        -- check ordered chapters
        if chap and edition:get_child(mk.chapters.EditionFlagOrdered).value == 1 then
            self.used_features[MK_FEATURE.ordered_chapters] = true
            is_ordered = true
        end

        -- loop EditionDisplays
        display, d = edition:find_child(mk.chapters.EditionDisplay)
        while display do
            -- loop EditionLanguageIETF
            lng, l = display:find_child(mk.chapters.EditionLanguageIETF)
            while lng do
                self.available_chapters_langs[lng.value] = true -- save language
                lng, l = display:find_next_child(l)
            end
            
            display, d = edition:find_next_child(d)
            if display then self.used_features[MK_FEATURE.multiple_edition_names] = true end
        end

        -- Tags
        if mk_file.Tags then
            local counter = 0
            tag = mk_file.Tags:find_Tag_byName(edition, "TITLE")
            if tag then
                local simple, s = tag:find_child(mk.tags.SimpleTag)
                while simple do
                    if simple:get_child(mk.tags.TagName).value == "TITLE" then
                        lng = simple:get_child(mk.tags.TagLanguage).value
                        self.available_chapters_langs[lng] = true -- save (old)language
                        lng = simple:find_child(mk.tags.TagLanguageBCP47)
                        if lng then
                            self.available_chapters_langs[lng.value] = true -- save BCP47 language
                        end
                        if not self.used_features[MK_FEATURE.multiple_edition_names] then
                            counter = counter + 1
                            if counter > 1 then self.used_features[MK_FEATURE.multiple_edition_names] = true end
                        end
                    end

                    simple, s = tag:find_next_child(s)
                end
            end
        end

        -- loop chapters
        while chap do
            process_chapter(chap, 0)
            chap, c = edition:find_next_child(c)
        end
        
        edition, e = mk_file.Chapters:find_next_child(e)
    end
end

-- _check_hard_linking (private): check and prepares everything
function Mk_Playback:_check_hard_linking()
    -- check init file
    local used, sid, pid, nid = self.init_file:hardlinking_is_used()
    if not used then return end

    local paths = utils.readdir(self.init_dir, "files")
    if not paths then msg.error("Could not read directory '"..self.init_dir.."'") return end

    -- save the init prev and next UIDs
    local start_pid = pid
    local start_nid = nid
    self.temp_files = {}
    local segments = {}
    local mk_file
    self.mk_files = {}

    -- loop over the files
    for _, path in ipairs(paths) do
        path = self.init_dir..path
        -- check all paths, exclude the init_file        
        if path ~= self.init_file.path then
            mk_file = mkp.Matroska_Parser:new(path)
            if mk_file.is_valid then
                sid, pid, nid = mk_file:hardlinking_get_uids()
                if sid ~= nil then
                    table.insert(self.temp_files, mk_file)

                    segments[sid] = {
                        prev = pid,
                        next = nid,
                        idx  = #self.temp_files
                    }
                else
                    mk_file:close()
                end
            end
        end
    end
    if #self.temp_files == 0 then return end

    table.insert(self.mk_files, self.init_file)

    -- endless loop check
    local function endless_loop(uid, start)
        -- it is possible(and easy) to build an endless loop with Hard-Linking
        -- for the prev-search we have to check all "left" files
        -- and for the next-search all "right" files
        -- the init_file is included in both search methods

        if start == nil then start = 1 end

        for i = start, #self.mk_files do
            if self.mk_files[i].seg_uuid == uid then return true end
        end
        return false
    end

    -- start backward search - prev ids
    if start_pid ~= nil then
        pid = start_pid

        while pid and segments[pid] do
            -- check endless looping
            if endless_loop(pid) then break end -- finish backward search
            -- insert in front
            table.insert(self.mk_files, 1, self.temp_files[segments[pid].idx])
            pid = segments[pid].prev
        end

        -- finish backward search, the first mk_file is now the main file
        -- again are the Chapters important and can break Hard-Linking at this point,
        -- when the default edition of this first main file has ordered chapters
        if #self.mk_files > 1 and self.mk_files[1]:ordered_chapters_are_used() then
            self:_close_files()
            return
        end
    end

    -- start forward search - next ids
    if start_nid then
        local start = #self.mk_files -- start index -> is the init_file
        nid = start_nid

        while nid and segments[nid] do
            -- check endless looping
            if endless_loop(nid, start) then break end -- finish forward search
            -- append
            table.insert(self.mk_files, self.temp_files[segments[nid].idx])
            nid = segments[nid].next
        end
    end

    -- check if another file was added
    if #self.mk_files == 1 then -- no file was added
        -- clean temp_ and mk_files
        self.mk_files = {}
        self:_close_files(true)
        return
    end

    -- Hard-Linking is used
    self.used_features[MK_FEATURE.hard_linking] = true
end

-- _build_timelines (private): generates for each edition a virtual chapter_timeline
function Mk_Playback:_build_timelines()
    self.internal_editions = {}

    local mk_file = self:_get_main_file()
    if mk_file == nil then return end

    local intern_edition
    local linked_editions -- a list of already all used linked edition uid's
    
    local run_time = 0

    -- load files, only needed for linked-chapters, some content is located in other files
    if self.used_features[MK_FEATURE.linked_chapters] then
        local files = utils.readdir(self.init_dir, "files")
        if not files then msg.error("Mk_Playback:_build_timelines()", "Could not read directory '"..self.init_dir.."'") return end

        -- loop over the files
        for _, file in ipairs(files) do
            local path = self.init_dir .. file
            -- check all paths, exclude the init_file        
            if path ~= mk_file.path then
                local mkf = mkp.Matroska_Parser:new(path)
                if mkf.is_valid and mkf.seg_uuid then
                    table.insert(self.temp_files, mkf)
                end
            end
        end
    end

    -- get linked file
    local function get_linked_file(s_id)
        -- search in mk_files first
        for i, file in ipairs(self.mk_files) do
            if file.seg_uuid == s_id then
                return file
            end
        end

        -- search in temp_files
        for i, file in ipairs(self.temp_files) do
            if file.seg_uuid == s_id then
                table.insert(self.mk_files, file)
                table.remove(self.temp_files, i)
                return file
            end
        end

        -- check init_file
        if self.init_file.seg_uuid == s_id then
            return self.init_file
        end
        return nil
    end
    
    
    -- process edition
    local function process_edition(ed, nested_level, file)
        -- prev_start_time: this var is used for non-ordered editions
        -- without an end time it is not possible to calculate the duration
        -- the duration of a chapter must be calculated from a next chapter's start time
        -- for the last chapter is the duration calculated from the video(/file) duration
        local prev_start_time = 0

        -- check edition is hidden
        local ed_is_hidden = ed:is_hidden()
        -- check ordered edition
        local ed_is_ordered = ed:is_ordered()
        -- first_chap: boolean, used for non-ordered editions
        local first_chap = true
        -- added_chap_idx: integer, index of the chapter segment, used for non-ordered editions
        local added_chap_idx

        -- process chapter
        local function process_chapter(chp, level)
            -- no process for disabled chapters, for the moment
            if chp:get_child(mk.chapters.ChapterFlagEnabled).value == 0 then return end

            -- start time
            local start_time = chp:get_child(mk.chapters.ChapterTimeStart).value

            -- ordered chapter
            if ed_is_ordered then
                -- end time
                local end_time = chp:find_child(mk.chapters.ChapterTimeEnd)
                if end_time then end_time = end_time.value else end_time = 0 end

                -- linked-chapter or linked-edition
                local c_seg_id = chp:find_child(mk.chapters.ChapterSegmentUUID)
                if c_seg_id then
                    c_seg_id = mkp.Matroska_Parser:_bin2hex(c_seg_id.value)
                    -- try to find the linked file
                    local linked_file = get_linked_file(c_seg_id)

                    -- no linked file found
                    if not linked_file then return end -- this skips also all nested chapters of this chapter

                    -- linked-Edition
                    local c_seg_edition_id = chp:find_child(mk.chapters.ChapterSegmentEditionUID)
                    if c_seg_edition_id then
                        --TODO: no chapters in the linked file
                        if linked_file.Chapters == nil then
                            -- no chapters no editions
                            -- to skip this linked chapter is simple but I think it's better to use the entire file
                            -- add a virtual chapter for that
                            return -- skip fully for the moment
                        end

                        c_seg_edition_id = c_seg_edition_id.value

                        -- check if the linked Edition exists in the linked file
                        local linked_edition = linked_file.Chapters:get_edition(nil, c_seg_edition_id)
                        if not linked_edition then return end -- invalid linking

                        -- check endless loop, Edition UID is already in the list
                        if linked_editions[c_seg_edition_id] then return end

                        -- process the linked edition
                        linked_editions[c_seg_edition_id] = true -- add this edition uid
                        process_edition(linked_edition, level, linked_file)

                    else -- linked-chapter, use chapter duration
                        -- add chapter segment
                        intern_edition:add_chapter_segment(chp, linked_file.path, run_time, level, ed_is_hidden)
                        -- increase runtime
                        if end_time > start_time then
                            run_time = run_time + (end_time - start_time)
                        end
                    end


                else -- no ChapterSegmentUUID -> normal ordered chapter
                    -- add chapter segment
                    intern_edition:add_chapter_segment(chp, file.path, run_time, level, ed_is_hidden)
                    -- increase runtime
                    if end_time > start_time then
                        run_time = run_time + (end_time - start_time)
                    end
                end

            
            else -- non-ordered chapter
                -- the run_time must be increased befor the chapter_segment is insert

                -- increase run_time
                if start_time > prev_start_time then
                    run_time = run_time + (start_time - prev_start_time)
                    prev_start_time = start_time -- new prev start time
                end
                -- add a chapter segment
                added_chap_idx = intern_edition:add_chapter_segment(chp, file.path, run_time, level, ed_is_hidden)

                -- set an end time for the prev chapter segment, start after first chapter
                if not first_chap then
                    intern_edition:add_chap_endtime(added_chap_idx -1, start_time)
                end
            end

            -- nested chapters
            if level > 8 then return end
            local nchap, nc = chp:find_child(mk.chapters.ChapterAtom)
            while nchap do
                process_chapter(nchap, level + 1)
                nchap, nc = chp:find_next_child(nc)
            end
        end
        

        -- find first chapter
        local chap, c = ed:find_child(mk.chapters.ChapterAtom)
        
        -- check first chapter
        if chap then
            -- check start time for non-ordered-editions
            if not ed_is_ordered then
                local stime = chap:get_child(mk.chapters.ChapterTimeStart).value
                -- when stime is not 0 then add a virtual chapter in the chapter_timeline
                if stime > 0 then
                    intern_edition:add_virtual_segment(file.path, run_time, nested_level)
                end
            end
        
        else -- there is no chapter in the edition
            -- add a virtual segment of the entire video duration
            local duration = file:get_video_duration() or file.seg_duration
            intern_edition:add_virtual_segment(file.path, run_time, nested_level, 0, duration)
            run_time = run_time + duration -- increase run_time
            return
        end

        -- loop chapters
        while chap do
            process_chapter(chap, nested_level)
            first_chap = false
            chap, c = ed:find_next_child(c)
        end

        -- non-ordered editions, increase the run_time using the video duration to get the duration for the last chapter
        if not ed_is_ordered then
            local duration = file:get_video_duration() or file.seg_duration
            if duration > prev_start_time then
                run_time = run_time + (duration - prev_start_time)
            end

            -- set an end time for the last chapter
            intern_edition:add_chap_endtime(added_chap_idx, duration)
        end

    end


    -- edition_idx, an index of an edition in the Matroksa file
    local edition_idx = 0 -- this value is needed for Hard-Linking to find the correct edition in other files

    -- process hard-linked files
    local function process_hard_linked_files()
        -- found edition: boolean, true when the edition could be found
        local found_edition

        -- process all files exclude the first one
        for i = 2, #self.mk_files do
            found_edition = false

            -- check if chapters are present
            if self.mk_files[i].Chapters then
                local ed = self.mk_files[i].Chapters:get_edition(edition_idx)
                if ed and not ed:is_ordered() then -- no ordered-chapter for the moment
                    -- only one scenario where ordered chapters are fine when the times are seamless until the video duration ends

                    found_edition = true
                    process_edition(ed, 0, self.mk_files[i])
                end
            end

            -- no chapters in the file or not the correct edition index or the edition is ordered
            if not found_edition then
                -- add a virtual segment of the entire video duration
                local duration = self.mk_files[i]:get_video_duration() or self.mk_files[i].seg_duration
                intern_edition:add_virtual_segment(self.mk_files[i].path, run_time, 0, 0, duration)
                run_time = run_time + duration -- increase run_time
            end
        end
    end


    -- loop main file editions
    local edition, e = mk_file.Chapters:find_child(mk.chapters.EditionEntry)
    while edition do
        run_time = 0
        edition_idx = edition_idx + 1
        intern_edition = Internal_Edition:new()
        intern_edition.ordered = edition:is_ordered()

        -- ordered edition
        if intern_edition.ordered then
            linked_editions = {} -- init empty array
            local uid = edition:find_child(mk.chapters.EditionUID)
            if uid then
                linked_editions[uid.value] = true -- add own UID to prevent endless looping
            end
        end

        -- check for Hard-Linking
        if self.used_features[MK_FEATURE.hard_linking] then
            --  no ordered editions in the main file allowed
            if intern_edition.ordered then
                -- add a virtual segment of the entire video duration
                local duration = mk_file:get_video_duration() or mk_file.seg_duration
                intern_edition:add_virtual_segment(mk_file.path, run_time, 0, 0, duration)
                run_time = run_time + duration -- increase run_time

            else -- non-ordered edition
                process_edition(edition, 0, mk_file) -- process the main edition
            end

            -- process all hard-linked file editions
            process_hard_linked_files()
            -- set intern_edition ordered to true, this is needed to generate the EDL path correctly
            intern_edition.ordered = true


        else -- no Hard-Linking
            process_edition(edition, 0, mk_file)
        end
        
        -- save the run_time
        intern_edition.duration = run_time
        -- create edl_path
        intern_edition:create_edl_path()

        -- add internal edition
        table.insert(self.internal_editions, intern_edition)

        edition, e = mk_file.Chapters:find_next_child(e)
    end

    -- set active edl_path
    self.edl_path = self.internal_editions[self.current_edition_idx].edl_path
end

-- _set_edition_names (private): a method to change the edition depend on the given languages
function Mk_Playback:_set_edition_names(langs)
    -- langs: array with language codes, when nil the first name is used
    if langs == nil then langs = {""} end -- no language code -> first name

    local c_name
    local mk_file = self:_get_main_file()
    if not mk_file then return end

    -- loop of the internal editions
    for i = 1, #self.internal_editions do
        c_name = ""

        -- find edition name
        for _, lng in ipairs(langs) do
            -- check lng, nothing todo if the current_lang match
            if lng == self.internal_editions[i].current_lang then break end

            c_name = mk_file:get_edition_name(i, lng, false, true)

            -- name found
            if c_name ~= "" then
                self.internal_editions[i].current_name = c_name
                self.internal_editions[i].current_lang = lng -- set new language
                break
            end
        end

        -- no new name found and current_name is empty
        if c_name == "" and self.internal_editions[i].current_name == "" then
            c_name = mk_file:get_edition_name(i, "") -- get first edition name
            -- check again, name could be empty -> no chapter Tag/Display or a really empty name
            if c_name == "" then c_name = "Edition " .. i end
            self.internal_editions[i].current_name = c_name
            self.internal_editions[i].current_lang = ""
        end
        
    end
end

-- _change_edition_chapter_names (private): set new names
function Mk_Playback:_change_edition_chapter_names(pref_sub_lang)
    -- check multiple chapter/edition names
    if self.used_features[MK_FEATURE.multiple_chapter_names]
    or self.used_features[MK_FEATURE.multiple_edition_names] then
        -- set new chapter and edition names
        local c_list = self:get_mpv_chapters(false, pref_sub_lang)
        if c_list then
            mp.set_property_native("chapter-list", c_list)
        end
    end

    -- set new media title 
    if self.used_features[MK_FEATURE.multiple_edition_names] then
        self:mpv_set_media_title()
    end
end

-- export --
return {
    Mk_Playback = Mk_Playback
}
