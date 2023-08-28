-- Matroska Playback
-- a library to handle Matoska features for playback with mpv
-- written by hubblec4

local mk = require "matroska"
local mkp = require "matroskaparser"
--local mp = require "mp"
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

-- new_internal_edition_item: returns an edition item for internal use
local function new_internal_edition_item()
    return {edl_path = "", main_file_idx = 0} -- main_file_idx = 0 means no extern file, init_file is main file
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

    -- mpv_editions: the same list as mpv use Array{Item{id, title, default}}
    mpv_editions = {},

    -- mpv_chapters: the same list as mpv use Array{Item{title, time}}
    mpv_chapters = {},

    -- mpv_current_vid: mpv number for video streams, start with 1, 0 = not used
    mpv_current_vid = 0,

    -- mpv_current_aid: mpv number for audio streams, start with 1, 0 = not used
    mpv_current_aid = 0,

    -- mpv_current_sid: mpv number for subtitle streams, start with 1, 0 = not used
    mpv_current_sid = 0,

    -- current_chapters_lang: language for edition and chapter names
    current_chapters_lang = "",

    -- available_chapters_langs: array[lng = true]
    available_chapters_langs = {},

    -- current_edition_idx: integer, a 0-based index
    current_edition_idx = 0,

    -- internal_editions: array, a list of edition items with useful info
    internal_editions = {} -- edition{{edl_path = "", main_file_idx = 0}}
}

-- constructor
function Mk_Playback:new(path)
    local elem = {}
    setmetatable(elem, self)
    self.__index = self
    elem.current_chapters_lang = nil -- use nil for init
    elem:_scan(path)
    return elem
end

-- closs: clean some var's
function Mk_Playback:close()
    if self.init_file then self.init_file:close() end
    self:_close_files()
end

-- init_chapters: init editions and chapters, after file is loaded
function Mk_Playback:init_chapters()
    -- at this point all current used stream id's are available
    local file, trk
    local lng = ""

    file = self:_get_main_file()
    if not file then return end

    -- audio language
    if self.mpv_current_aid > 0 then
        trk = file:get_audio(self.mpv_current_aid - 1)
        if trk then
            lng = trk:get_language()
            if self.available_chapters_langs[lng] then
                self:prepare_editions_chapters(lng)
                return
            end
        end
    end

    -- subtitle language
    if self.mpv_current_sid > 0 then
        trk = file:get_subtitle(self.mpv_current_sid -1)
        if trk then
            lng = trk:get_language()
        end
    end
    self:prepare_editions_chapters(lng)
end

-- prepare_editions_chapters: prepare the edition and chapter list
function Mk_Playback:prepare_editions_chapters(language)
    if language == self.current_chapters_lang then return end

    -- Hard-Linking chapters
    if self.used_features[MK_FEATURE.hard_linking] then
        -- first file is used for the editions
        self:_prepare_editions(self.mk_files[1])
        if #self.mpv_editions == 0 then return end -- no edition, no chapters

        local run_time = 0
        -- loop over all used mk_files for the chapters
        for _, file in ipairs(self.mk_files) do
            if file.Chapters then
                self:_prepare_chapters(file.Chapters:get_edition(self.current_edition_idx), language, run_time)
            end

            -- increase run_time by video-duration
            --TODO: what is when there is no video or no audio -> I guess then is the Segment-Duration fine
            run_time = run_time + file:get_video_duration(file.Tracks:get_track(self.mpv_current_vid - 1))
        end
        
    -- TODO: other's
    else
        if self.init_file.Chapters then
            self:_prepare_editions(self.init_file)
            self:_prepare_chapters(self.init_file.Chapters:get_edition(self.current_edition_idx), language)
        end
    end
    self.current_chapters_lang = language -- set new used language
end

-- on_edition_change: event when in mpv the edititon is changed
function Mk_Playback:on_edition_change(new_idx)
    self.current_edition_idx = new_idx
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
    self:_build_timeline()
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
        return self.mk_files[self.internal_editions[self.current_edition_idx].main_file_idx]
    end

    -- no specials
    return self.init_file
end

-- _analyze_chapters (private): analyze the chapters structure
function Mk_Playback:_analyze_chapters()
    local mk_file = self:_get_main_file()
    self.available_chapters_langs = {}
    if mk_file == nil or mk_file.Chapters == nil then
        self.current_edition_idx = -1
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
    if mk_file.Chapters:get_edition(1)  then
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

-- _prepare_editions (private): prepare mpv editions
function Mk_Playback:_prepare_editions(mfile, language)
    if mfile == nil then return end
    local chaps = mfile.Chapters
    if language == self.current_chapters_lang or chaps == nil then return end

    local uid
    self.mpv_editions = {}
    local edition, i = chaps:find_child(mk.chapters.EditionEntry)
    while edition do
        uid = edition:find_child(mk.chapters.EditionUID)
        if uid then
            uid = uid.value
        else
            uid = #self.mpv_editions
        end

        -- add edition
        table.insert(self.mpv_editions,
            {id = uid
            ,title = mfile:get_edition_name(edition, language)
            ,default = edition:get_child(mk.chapters.EditionFlagDefault).value == 1})
        
        edition, i = chaps:find_next_child(i)
    end
end

-- _prepare_chapters (private): prepare mpv chapters
function Mk_Playback:_prepare_chapters(edition, language, time_offset)
    if not time_offset then
		self.mpv_chapters = {} -- init empty array
	end

    if language == self.current_chapters_lang or edition == nil then return end
    --[[ if "language" is set then chapter name(s) with this language will be used
        otherwise always the first chapter name is used

        time_offset in nanosecs: is usefull when the chapters are created for Hard-Linking
    ]]

    if edition:is_hidden() then return end

    --if language == nil then language = "" end

    local start_time, end_time
    local run_time = 0
    if time_offset then run_time = time_offset end
    
    local e_ordered = edition:is_ordered()

    local function add_chapter(time, title, level)
        if title == "" then
            title = " "  -- a space is used to prevent auto chapternaming
        else -- nested chapters level
            local nested = ""
            for i = 1, level do
                nested = nested .. "+"
            end
            if nested ~= "" then
                nested = " " .. nested .. " "
            end
            title = nested .. title
        end
        table.insert(self.mpv_chapters, {time = time / 1000000000, title = title})
    end

    local function process_chapter(chp, level)
        if chp == nil
        -- ignore disabled chapters fully
        or not chp:is_enabled() then return end
        
        start_time = chp:get_child(mk.chapters.ChapterTimeStart).value

        -- ordered chapters
        if e_ordered then
            if not chp:is_hidden() then
                add_chapter(run_time, chp:get_name(language), level)
            end
            -- find end-time element
            end_time = chp:find_child(mk.chapters.ChapterTimeEnd)
            --[[ ordered chapters uses a duration to play a specific content
                 we need a positiv duration, means end_time must be greater than start_time
                 zero duration: such chapters are ignored by the players for the virtual timeline
                 thats fine, but the content of the chapter should not be skipped
                 a chapter name could be used also the ChapProcess element can have some instructions

                 I will try to support zero-duration(and negative) chapters to support nested-ordered-chapters
            ]]
            if end_time then
                end_time = end_time.value
            else
                end_time = 0
            end
            -- increase the run_time only if end_time greater than start_time
            if end_time > start_time then
                run_time = run_time + (end_time - start_time)
            end

        -- normal chapters, must be visible
        elseif not chp:is_hidden() then
            add_chapter(start_time + run_time, chp:get_name(language), level)
        end
        
        -- process nested chapters
        -- nesting can be endless, support max 9 levels include the base level(0)
        if level > 8 then return end
        local nchap, nc = chp:find_child(mk.chapters.ChapterAtom)
        while nchap do
            process_chapter(nchap, level + 1)
            nchap, nc = chp:find_next_child(nc)
        end
        
    end

    local chapter, idx = edition:find_child(mk.chapters.ChapterAtom)
    while chapter do
        process_chapter(chapter, 0)
        chapter, idx = edition:find_next_child(idx)
    end

end

-- _build_timeline (private): generates the virtual seamless timeline(s) depend on the used chapters features using mpv edl system
function Mk_Playback:_build_timeline()
    self.internal_editions = {}

    -- Hard-Linking
    if self.used_features[MK_FEATURE.hard_linking] then
        self.edl_path = "edl://!no_chapters;"
        for _, file in ipairs(self.mk_files) do
            self.edl_path = self.edl_path .. ("%%%d%%%s,0,%f;"):format(file.path:len(), file.path, file:get_video_duration() / 1000000000)
        end
        return
    end

    local mk_file = self:_get_main_file()
    if mk_file == nil then return end

    
    -- all ordered-chapters features needs a special timeline creation
    -- linked-chapters, linked-editions, nested-ordered-chapters, linked-chapters-file
    if self.used_features[MK_FEATURE.ordered_chapters] then

        local extern_files_loaded = false
        local linked_file, idx
        local intern_edition
        local link_list = {} -- a list with linked chapter items
        local start_time, end_time

        -- load files
        local function load_files()
            extern_files_loaded = true
            local paths = utils.readdir(self.init_dir, "files")
            if not paths then msg.error("Could not read directory '"..self.init_dir.."'") return end

            -- loop over the files
            for _, path in ipairs(paths) do
                path = self.init_dir..path
                -- check all paths, exclude the init_file        
                if path ~= mk_file.path then
                    local mkf = mkp.Matroska_Parser:new(path)
                    if mkf.is_valid then
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
                    return file, i
                end
            end

            -- search in temp_files
            for i, file in ipairs(self.temp_files) do
                if file.seg_uuid == s_id then
                    table.insert(self.mk_files, file)
                    table.remove(self.temp_files, i)
                    return file, #self.mk_files
                end
            end
            return nil
        end

        -- add linked_chapter
        local function add_linked_chapter()
            if linked_file == nil or start_time >= end_time then return end
            table.insert(link_list, {s_t = start_time, e_t = end_time, path = linked_file.path})
        end

        -- process link_list
        local function process_link_list()
            --[[ it is possible to merge linked chapters if the timestamps are seamless
            ]]

            -- reference index for a linked chapter entry
            local ref_idx = #link_list -- init last entry

            -- loop backward over the list, start second to last 
            for i = ref_idx -1, 1 , -1 do
                -- check same file
                if link_list[i].path == link_list[ref_idx].path then
                    -- check times
                    if link_list[i].e_t == link_list[ref_idx].s_t then
                        link_list[ref_idx].s_t = link_list[i].s_t -- new start time
                        table.remove(link_list, i)
                        ref_idx = ref_idx - 1

                    -- times do not match
                    else
                        ref_idx = i -- new ref index
                    end
                    
                -- new file
                else
                    ref_idx = i -- new ref index
                end
            end

            -- build the edl_path from the linked chapters
            for _, lc in ipairs(link_list) do
                intern_edition.edl_path = intern_edition.edl_path .. ("%%%d%%%s,%f,%f;"):format(lc.path:len(),
                lc.path, lc.s_t / 1000000000, (lc.e_t -lc.s_t) / 1000000000)
            end
        end

        -- process chapters
        local function process_chapter(chp, level)
            -- no process for disabled chapters
            if chp:get_child(mk.chapters.ChapterFlagEnabled).value == 0 then return end

            local c_seg_id = chp:find_child(mk.chapters.ChapterSegmentUUID)
            if c_seg_id then c_seg_id = mkp.Matroska_Parser:_bin2hex(c_seg_id.value) end
            local c_seg_edition_id = chp:find_child(mk.chapters.ChapterSegmentEditionUID)
            if c_seg_edition_id then c_seg_edition_id = c_seg_edition_id.value end

            -- need external files?
            if not extern_files_loaded and c_seg_id then
                load_files()
            end

            start_time = chp:get_child(mk.chapters.ChapterTimeStart).value
            end_time = chp:find_child(mk.chapters.ChapterTimeEnd)
            if end_time then end_time = end_time.value else end_time = 0 end
                
            -- linked-chapter
            if c_seg_id then
                linked_file, idx = get_linked_file(c_seg_id)

                if linked_file then
                    -- first linked file = main file
                    if intern_edition.main_file_idx == 0 then
                        intern_edition.main_file_idx = idx
                    end

                    -- linked-edition
                    if c_seg_edition_id then
                        --TODO:

                    else
                        add_linked_chapter()
                    end
                end

            -- nested-ordered-chapters
            else
                linked_file = mk_file -- main file is used
                add_linked_chapter()
            end

            -- nested chapters
            if level > 8 then return end
            local nchap, nc = chp:find_child(mk.chapters.ChapterAtom)
            while nchap do
                process_chapter(nchap, level + 1)
                nchap, nc = chp:find_next_child(nc)
            end
        end

        local edition, e = mk_file.Chapters:find_child(mk.chapters.EditionEntry)
        -- loop editions
        while edition do
            link_list = {} -- init link list empty
            intern_edition = new_internal_edition_item()

            -- ordered edition
            if edition:get_child(mk.chapters.EditionFlagOrdered).value == 1 then
                intern_edition.edl_path = "edl://!no_chapters;" -- init without chapters
    
                -- loop chapters
                local chap, c = edition:find_child(mk.chapters.ChapterAtom)
                while chap do
                    process_chapter(chap, 0)
                    chap, c = edition:find_next_child(c)
                end

                process_link_list()

            -- non-ordered edition
            else
                intern_edition.edl_path = intern_edition.edl_path .. ("%%%d%%%s;"):format(mk_file.path:len(), mk_file.path)
            end

            -- add internal edition
            table.insert(self.internal_editions, intern_edition)

            edition, e = mk_file.Chapters:find_next_child(e)
        end

        self.edl_path = self.internal_editions[self.current_edition_idx + 1].edl_path

        return
    end

    -- basic-chapters and nested-chapters, can be loaded without timeline generation
    -- also it is fine to use the entire file duration instead the video duration
    self.edl_path = ("edl://!no_chapters;%%%d%%%s;"):format(mk_file.path:len(), mk_file.path)
end

-- export --
return {
    Mk_Playback = Mk_Playback
}
