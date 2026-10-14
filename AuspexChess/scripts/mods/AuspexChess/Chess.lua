local mod = get_mod("AuspexChess")
local ROOT = "AuspexChess/scripts/mods/AuspexChess/"
local OVERLAY_VIEW_NAME = "auspex_chess_overlay_view"

-- assets

local chess_assets = (function()
    local TEXTURE_FILES = {
        "chess_white_pawn.png",
        "chess_white_knight.png",
        "chess_white_bishop.png",
        "chess_white_rook.png",
        "chess_white_queen.png",
        "chess_white_king.png",
        "chess_black_pawn.png",
        "chess_black_knight.png",
        "chess_black_bishop.png",
        "chess_black_rook.png",
        "chess_black_queen.png",
        "chess_black_king.png",
    }

    local api = {
        ready = false,
        loading = false,
        textures = {},
    }

    local function load_error(path, result)
        local reason = result and (result.error or result.url) or "no result returned"
        mod:error("AuspexChess failed loading asset '%s': %s", path, tostring(reason))
    end

    function api.load()
        if api.ready or api.loading then
            return
        end

        local simple_assets = get_mod("SimpleAssets")
        if not simple_assets or type(simple_assets.load_textures) ~= "function" then
            mod:error("AuspexChess requires SimpleAssets")
            return
        end

        api.loading = true
        simple_assets.load_textures(TEXTURE_FILES):next(function(results)
            local ready = true

            for i = 1, #TEXTURE_FILES do
                local path = TEXTURE_FILES[i]
                local result = results[path]

                if result and result.is_ok and result.texture then
                    local key = string.match(path, "^chess_(.+)%.png$")
                    if key then
                        api.textures[key] = result.texture
                    end
                else
                    ready = false
                    load_error(path, result)
                end
            end

            api.loading = false
            api.ready = ready
        end):catch(function(result)
            api.loading = false
            load_error("textures", result)
        end)
    end

    function api.texture(key)
        return api.textures[key]
    end

    return api
end)()
mod.chess_assets = chess_assets

-- lichess

local dataset = (function()
    local mod = get_mod("AuspexChess")

    local math_floor = math.floor
    local string_byte = string.byte
    local string_find = string.find
    local string_sub = string.sub
    local tostring = tostring
    local type = type

    local DATA_ROOT = "AuspexChess/scripts/mods/AuspexChess/lichess/"
    local INDEX = mod:io_dofile(DATA_ROOT .. "index")
    local BAND_NAMES = { "easy", "normal", "hard", "expert" }
    local VALID_DIFFICULTIES = {
        easy = true,
        normal = true,
        hard = true,
        expert = true,
        mixed = true,
    }

    local RNG_MOD = 2147483647
    local RNG_MUL = 48271

    fassert(type(INDEX) == "table" and type(INDEX.bands) == "table", "AuspexChess chess index failed to load.")

    local api = {}

    local function normalize_seed(seed)
        if type(seed) == "number" then
            seed = math_floor(seed) % RNG_MOD
            return seed > 0 and seed or 1
        end

        local text = tostring(seed or "AuspexChess")
        local value = 1

        for i = 1, #text do
            value = (value * 131 + string_byte(text, i)) % RNG_MOD
        end

        return value > 0 and value or 1
    end

    local function random_int(state, low, high)
        state.value = state.value * RNG_MUL % RNG_MOD
        return low + state.value % (high - low + 1)
    end

    local function choose_band(rng, difficulty)
        if difficulty ~= "mixed" then
            return INDEX.bands[difficulty]
        end

        local pick = random_int(rng, 1, INDEX.total)
        local cumulative = 0

        for i = 1, #BAND_NAMES do
            local band = INDEX.bands[BAND_NAMES[i]]
            cumulative = cumulative + band.count
            if pick <= cumulative then
                return band
            end
        end

        return INDEX.bands.normal
    end

    local function split_record(line, fields)
        local count = 0
        local start = 1

        while true do
            local at = string_find(line, ",", start, true)
            count = count + 1

            if at then
                fields[count] = string_sub(line, start, at - 1)
                start = at + 1
            else
                fields[count] = string_sub(line, start)
                break
            end
        end

        if count < 3 then
            return nil
        end

        return {
            id = fields[1],
            fen = fields[2],
            moves = fields[3],
        }
    end

    local function row_from_content(content, row)
        local start = 1

        for _ = 2, row do
            local line_end = string_find(content, "\n", start, true)
            if not line_end then
                return nil
            end
            start = line_end + 1
        end

        local line_end = string_find(content, "\n", start, true)
        local line = line_end and string_sub(content, start, line_end - 1) or string_sub(content, start)

        if string_sub(line, -1) == "\r" then
            line = string_sub(line, 1, -2)
        end

        return line ~= "" and line or nil
    end

    local function choose_record(band, rng)
        local shards = band and band.shards
        if not shards or #shards == 0 or not band.count or band.count <= 0 then
            return nil, nil
        end

        local pick = random_int(rng, 1, band.count)
        for i = 1, #shards do
            local shard = shards[i]
            if pick <= shard.count then
                return shard, pick
            end
            pick = pick - shard.count
        end

        return nil, nil
    end

    function api.normalize_difficulty(value)
        return VALID_DIFFICULTIES[value] and value or "normal"
    end

    function api.random_record(seed, difficulty)
        difficulty = api.normalize_difficulty(difficulty)

        local rng = { value = normalize_seed(seed) }
        local band = choose_band(rng, difficulty)
        local shard, row = choose_record(band, rng)

        if not shard or not row then
            return nil, "chess_band_empty"
        end

        local content = mod:io_read_content(DATA_ROOT .. shard.file, "csv")
        if type(content) ~= "string" then
            return nil, "chess_shard_unavailable"
        end

        local line = row_from_content(content, row)
        if not line then
            return nil, "chess_shard_row_missing"
        end

        local record = split_record(line, {})
        if not record then
            return nil, "chess_shard_row_invalid"
        end

        return record
    end

    return api
end)()

-- board

local rules = (function()
    local string_byte = string.byte
    local string_char = string.char
    local string_find = string.find
    local string_gsub = string.gsub
    local string_lower = string.lower
    local string_match = string.match
    local string_sub = string.sub
    local string_upper = string.upper
    local tonumber = tonumber
    local math_abs = math.abs
    local math_floor = math.floor


    local function square_to_coords(square)
        if type(square) ~= "string" or #square ~= 2 then
            return nil
        end

        local file = string_byte(square, 1) - 96
        local rank = tonumber(string_sub(square, 2, 2))

        if file < 1 or file > 8 or not rank or rank < 1 or rank > 8 then
            return nil
        end

        return file, rank
    end

    local function coords_to_index(file, rank)
        if file < 1 or file > 8 or rank < 1 or rank > 8 then
            return nil
        end

        return (8 - rank) * 8 + file
    end

    local function index_to_coords(index)
        if not index or index < 1 or index > 64 then
            return nil
        end

        local row = math_floor((index - 1) / 8)
        local file = index - row * 8
        local rank = 8 - row
        return file, rank
    end

    local function coords_to_square(file, rank)
        if file < 1 or file > 8 or rank < 1 or rank > 8 then
            return nil
        end

        return string_char(96 + file) .. string_char(48 + rank)
    end

    local function square_to_index(square)
        local file, rank = square_to_coords(square)
        return file and coords_to_index(file, rank) or nil
    end

    local function index_to_square(index)
        local file, rank = index_to_coords(index)
        return file and coords_to_square(file, rank) or nil
    end

    local function piece_side(piece)
        if not piece then
            return nil
        end

        return string_upper(piece) == piece and "w" or "b"
    end

    local function other_side(side)
        return side == "w" and "b" or "w"
    end

    local function remove_castling(rights, chars)
        if rights == "-" then
            return rights
        end

        for i = 1, #chars do
            rights = string_gsub(rights, string_sub(chars, i, i), "")
        end

        return rights == "" and "-" or rights
    end

    local function parse_fen(fen, state)
        local board_part, side, castling, en_passant, halfmove, fullmove = string_match(
            fen or "",
            "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)"
        )

        if not board_part or (side ~= "w" and side ~= "b") then
            return false, "invalid_fen"
        end

        local board = state.board
        for i = 1, 64 do
            board[i] = false
        end

        local row = 1
        local column = 1

        for i = 1, #board_part do
            local ch = string_sub(board_part, i, i)

            if ch == "/" then
                if column ~= 9 or row >= 8 then
                    return false, "invalid_fen_board"
                end

                row = row + 1
                column = 1
            else
                local empty = tonumber(ch)

                if empty then
                    if empty < 1 or empty > 8 or column + empty > 9 then
                        return false, "invalid_fen_board"
                    end
                    column = column + empty
                else
                    if not string_find("prnbqkPRNBQK", ch, 1, true) or column > 8 then
                        return false, "invalid_fen_board"
                    end

                    board[(row - 1) * 8 + column] = ch
                    column = column + 1
                end
            end
        end

        if row ~= 8 or column ~= 9 then
            return false, "invalid_fen_board"
        end

        state.side_to_move = side
        state.castling = castling
        state.en_passant = en_passant
        state.halfmove = tonumber(halfmove) or 0
        state.fullmove = tonumber(fullmove) or 1
        return true
    end

    local function apply_uci(state, move)
        move = string_lower(move or "")
        if #move < 4 or #move > 5 then
            return false, "invalid_uci"
        end

        local from_square = string_sub(move, 1, 2)
        local to_square = string_sub(move, 3, 4)
        local promotion = #move == 5 and string_sub(move, 5, 5) or nil

        if promotion and not string_find("qrbn", promotion, 1, true) then
            return false, "invalid_promotion"
        end

        local from = square_to_index(from_square)
        local to = square_to_index(to_square)

        if not from or not to then
            return false, "invalid_square"
        end

        local board = state.board
        local piece = board[from]
        if not piece then
            return false, "empty_from_square"
        end
        if piece_side(piece) ~= state.side_to_move then
            return false, "wrong_side_to_move"
        end

        local from_file, from_rank = square_to_coords(from_square)
        local to_file, to_rank = square_to_coords(to_square)
        local lower_piece = string_lower(piece)
        local captured = board[to]
        local old_ep = state.en_passant

        if lower_piece == "p"
            and not captured
            and old_ep ~= "-"
            and to_square == old_ep
            and from_file ~= to_file then
            local captured_rank = piece == "P" and to_rank - 1 or to_rank + 1
            local captured_index = coords_to_index(to_file, captured_rank)
            captured = captured_index and board[captured_index] or false

            if captured_index then
                board[captured_index] = false
            end
        end

        if lower_piece == "k" and math_abs(to_file - from_file) == 2 then
            local rook_from_file = to_file > from_file and 8 or 1
            local rook_to_file = to_file > from_file and 6 or 4
            local rook_from = coords_to_index(rook_from_file, from_rank)
            local rook_to = coords_to_index(rook_to_file, from_rank)

            if not rook_from or not rook_to or string_lower(board[rook_from] or "") ~= "r"
                or piece_side(board[rook_from]) ~= piece_side(piece) then
                return false, "invalid_castle"
            end

            board[rook_to] = board[rook_from]
            board[rook_from] = false
        end

        board[from] = false

        if promotion and lower_piece == "p" then
            piece = piece == "P" and string_upper(promotion) or promotion
        end

        board[to] = piece

        local rights = state.castling

        if lower_piece == "k" then
            rights = piece_side(piece) == "w" and remove_castling(rights, "KQ") or remove_castling(rights, "kq")
        elseif lower_piece == "r" then
            if from_square == "a1" then rights = remove_castling(rights, "Q")
            elseif from_square == "h1" then rights = remove_castling(rights, "K")
            elseif from_square == "a8" then rights = remove_castling(rights, "q")
            elseif from_square == "h8" then rights = remove_castling(rights, "k") end
        end

        if captured then
            if to_square == "a1" then rights = remove_castling(rights, "Q")
            elseif to_square == "h1" then rights = remove_castling(rights, "K")
            elseif to_square == "a8" then rights = remove_castling(rights, "q")
            elseif to_square == "h8" then rights = remove_castling(rights, "k") end
        end

        state.castling = rights
        state.en_passant = "-"

        if lower_piece == "p" and math_abs(to_rank - from_rank) == 2 then
            local en_passant_rank = math_floor((from_rank + to_rank) * 0.5)
            state.en_passant = coords_to_square(from_file, en_passant_rank)
        end

        if lower_piece == "p" or captured then
            state.halfmove = 0
        else
            state.halfmove = state.halfmove + 1
        end

        if state.side_to_move == "b" then
            state.fullmove = state.fullmove + 1
        end

        state.side_to_move = other_side(state.side_to_move)
        return true
    end

    local KNIGHT_STEPS = {
        { -2, -1 }, { -2, 1 }, { -1, -2 }, { -1, 2 },
        { 1, -2 }, { 1, 2 }, { 2, -1 }, { 2, 1 },
    }
    local KING_STEPS = {
        { -1, -1 }, { -1, 0 }, { -1, 1 }, { 0, -1 },
        { 0, 1 }, { 1, -1 }, { 1, 0 }, { 1, 1 },
    }
    local BISHOP_RAYS = {
        { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 },
    }
    local ROOK_RAYS = {
        { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
    }


    local function square_attacked(state, file, rank, attacker_side)
        local board = state.board
        local pawn = attacker_side == "w" and "P" or "p"
        local pawn_source_rank = rank + (attacker_side == "w" and -1 or 1)

        for i = 1, 2 do
            local pawn_file = file + (i == 1 and -1 or 1)
            local index = coords_to_index(pawn_file, pawn_source_rank)
            if index and board[index] == pawn then
                return true
            end
        end

        local knight = attacker_side == "w" and "N" or "n"
        for i = 1, #KNIGHT_STEPS do
            local step = KNIGHT_STEPS[i]
            local index = coords_to_index(file + step[1], rank + step[2])
            if index and board[index] == knight then
                return true
            end
        end

        local king = attacker_side == "w" and "K" or "k"
        for i = 1, #KING_STEPS do
            local step = KING_STEPS[i]
            local index = coords_to_index(file + step[1], rank + step[2])
            if index and board[index] == king then
                return true
            end
        end

        for i = 1, #BISHOP_RAYS do
            local ray = BISHOP_RAYS[i]
            local x, y = file + ray[1], rank + ray[2]

            while x >= 1 and x <= 8 and y >= 1 and y <= 8 do
                local piece = board[coords_to_index(x, y)]
                if piece then
                    if piece_side(piece) == attacker_side then
                        local lower = string_lower(piece)
                        if lower == "b" or lower == "q" then
                            return true
                        end
                    end
                    break
                end
                x, y = x + ray[1], y + ray[2]
            end
        end

        for i = 1, #ROOK_RAYS do
            local ray = ROOK_RAYS[i]
            local x, y = file + ray[1], rank + ray[2]

            while x >= 1 and x <= 8 and y >= 1 and y <= 8 do
                local piece = board[coords_to_index(x, y)]
                if piece then
                    if piece_side(piece) == attacker_side then
                        local lower = string_lower(piece)
                        if lower == "r" or lower == "q" then
                            return true
                        end
                    end
                    break
                end
                x, y = x + ray[1], y + ray[2]
            end
        end

        return false
    end

    local function king_in_check(state, side)
        local king = side == "w" and "K" or "k"

        for index = 1, 64 do
            if state.board[index] == king then
                local file, rank = index_to_coords(index)
                return square_attacked(state, file, rank, other_side(side))
            end
        end

        return true
    end

    local function clone_state(state)
        local copy = {
            board = {},
            side_to_move = state.side_to_move,
            castling = state.castling,
            en_passant = state.en_passant,
            halfmove = state.halfmove,
            fullmove = state.fullmove,
        }

        for i = 1, 64 do
            copy.board[i] = state.board[i]
        end

        return copy
    end


    local function candidate_is_legal(state, move, side)
        local copy = clone_state(state)
        local ok = apply_uci(copy, move)
        return ok and not king_in_check(copy, side)
    end

    local function append_candidate(state, moves, from_file, from_rank, to_file, to_rank, side, promotion)
        local to_index = coords_to_index(to_file, to_rank)
        if not to_index then
            return
        end

        local target = state.board[to_index]
        if target and piece_side(target) == side then
            return
        end

        local move = coords_to_square(from_file, from_rank) .. coords_to_square(to_file, to_rank) .. (promotion or "")
        if candidate_is_legal(state, move, side) then
            moves[#moves + 1] = move
        end
    end

    local function append_slider_moves(state, moves, file, rank, side, rays)
        for i = 1, #rays do
            local ray = rays[i]
            local x, y = file + ray[1], rank + ray[2]

            while x >= 1 and x <= 8 and y >= 1 and y <= 8 do
                local target = state.board[coords_to_index(x, y)]
                if target then
                    if piece_side(target) ~= side then
                        append_candidate(state, moves, file, rank, x, y, side)
                    end
                    break
                end

                append_candidate(state, moves, file, rank, x, y, side)
                x, y = x + ray[1], y + ray[2]
            end
        end
    end

    local function append_castles(state, moves, file, rank, side)
        local board = state.board
        local home_rank = side == "w" and 1 or 8
        if file ~= 5 or rank ~= home_rank or king_in_check(state, side) then
            return
        end

        local opponent = other_side(side)
        local king_side_flag = side == "w" and "K" or "k"
        local queen_side_flag = side == "w" and "Q" or "q"
        local rook = side == "w" and "R" or "r"
        local rights = state.castling or "-"

        if string_find(rights, king_side_flag, 1, true)
            and board[coords_to_index(8, home_rank)] == rook
            and not board[coords_to_index(6, home_rank)]
            and not board[coords_to_index(7, home_rank)]
            and not square_attacked(state, 6, home_rank, opponent)
            and not square_attacked(state, 7, home_rank, opponent) then
            append_candidate(state, moves, file, rank, 7, home_rank, side)
        end

        if string_find(rights, queen_side_flag, 1, true)
            and board[coords_to_index(1, home_rank)] == rook
            and not board[coords_to_index(2, home_rank)]
            and not board[coords_to_index(3, home_rank)]
            and not board[coords_to_index(4, home_rank)]
            and not square_attacked(state, 4, home_rank, opponent)
            and not square_attacked(state, 3, home_rank, opponent) then
            append_candidate(state, moves, file, rank, 3, home_rank, side)
        end
    end

    local function legal_moves_from_square(state, square, output)
        output = output or {}
        for i = #output, 1, -1 do
            output[i] = nil
        end

        local file, rank = square_to_coords(square)
        if not file then
            return output
        end

        local piece = state.board[coords_to_index(file, rank)]
        local side = piece_side(piece)
        if not piece or side ~= state.side_to_move then
            return output
        end

        local lower = string_lower(piece)

        if lower == "p" then
            local direction = side == "w" and 1 or -1
            local start_rank = side == "w" and 2 or 7
            local promotion_rank = side == "w" and 8 or 1
            local one_rank = rank + direction
            local one_index = coords_to_index(file, one_rank)

            if one_index and not state.board[one_index] then
                append_candidate(
                    state, output, file, rank, file, one_rank, side,
                    one_rank == promotion_rank and "q" or nil
                )

                local two_rank = rank + direction * 2
                local two_index = coords_to_index(file, two_rank)
                if rank == start_rank and two_index and not state.board[two_index] then
                    append_candidate(state, output, file, rank, file, two_rank, side)
                end
            end

            for i = 1, 2 do
                local target_file = file + (i == 1 and -1 or 1)
                local target_rank = rank + direction
                local target_index = coords_to_index(target_file, target_rank)

                if target_index then
                    local target = state.board[target_index]
                    local target_square = coords_to_square(target_file, target_rank)
                    if target and piece_side(target) ~= side or state.en_passant ~= "-" and target_square == state.en_passant then
                        append_candidate(
                            state, output, file, rank, target_file, target_rank, side,
                            target_rank == promotion_rank and "q" or nil
                        )
                    end
                end
            end
        elseif lower == "n" then
            for i = 1, #KNIGHT_STEPS do
                local step = KNIGHT_STEPS[i]
                append_candidate(state, output, file, rank, file + step[1], rank + step[2], side)
            end
        elseif lower == "b" then
            append_slider_moves(state, output, file, rank, side, BISHOP_RAYS)
        elseif lower == "r" then
            append_slider_moves(state, output, file, rank, side, ROOK_RAYS)
        elseif lower == "q" then
            append_slider_moves(state, output, file, rank, side, BISHOP_RAYS)
            append_slider_moves(state, output, file, rank, side, ROOK_RAYS)
        elseif lower == "k" then
            for i = 1, #KING_STEPS do
                local step = KING_STEPS[i]
                append_candidate(state, output, file, rank, file + step[1], rank + step[2], side)
            end
            append_castles(state, output, file, rank, side)
        end

        return output
    end


    return {
        apply_uci = apply_uci,
        index_to_square = index_to_square,
        king_in_check = king_in_check,
        legal_moves_from_square = legal_moves_from_square,
        parse_fen = parse_fen,
        piece_side = piece_side,
        square_to_index = square_to_index,
    }
end)()

-- puzzle

local Puzzle = (function()

    local math_floor = math.floor
    local string_byte = string.byte
    local string_gmatch = string.gmatch
    local string_gsub = string.gsub
    local string_lower = string.lower
    local string_sub = string.sub
    local type = type

    local Puzzle = {}
    Puzzle.__index = Puzzle

    local function split_moves(text, output)
        local count = 0

        for move in string_gmatch(text or "", "%S+") do
            count = count + 1
            output[count] = move
        end

        for i = count + 1, #output do
            output[i] = nil
        end

        return count
    end

    local function normalize_uci(move)
        return type(move) == "string" and string_lower(string_gsub(move, "%s+", "")) or ""
    end

    function Puzzle.new(seed, options)
        options = options or {}
        local record = options.record
        local difficulty = dataset.normalize_difficulty(options.difficulty)

        if not record then
            local selected, reason = dataset.random_record(seed, difficulty)
            if not selected then
                return nil, reason
            end
            record = selected
        end

        local self = setmetatable({
            puzzle_id = record.id,
            difficulty = difficulty,
            fen = record.fen,
            board = {},
            moves = {},
            move_count = 0,
            next_move = 2,
            solved = false,
            last_auto_move = false,
            last_user_move = false,
            last_move = false,
            last_move_kind = false,
            player_side = "w",
            side_to_move = "w",
            castling = "-",
            en_passant = "-",
            halfmove = 0,
            fullmove = 1,
            _legal_move_buffer = {},
        }, Puzzle)

        local ok, reason = rules.parse_fen(record.fen, self)
        if not ok then
            return nil, reason
        end

        self.move_count = split_moves(record.moves, self.moves)
        if self.move_count < 2 then
            return nil, "puzzle_move_sequence_invalid"
        end

        local first = self.moves[1]
        ok, reason = rules.apply_uci(self, first)
        if not ok then
            return nil, "invalid_setup_move:" .. tostring(reason)
        end

        self.last_auto_move = first
        self.last_move = first
        self.last_move_kind = "opponent"
        self.player_side = self.side_to_move
        return self
    end

    function Puzzle:submit_move(move)
        if self.solved then
            return false, "finished"
        end

        local normalized = normalize_uci(move)
        local expected = self.moves[self.next_move]

        if normalized == "" then
            return false, "invalid_move"
        end

        if normalized ~= expected then
            return true, false, nil, false
        end

        local ok, reason = rules.apply_uci(self, normalized)
        if not ok then
            return false, reason
        end

        self.last_user_move = normalized
        self.last_move = normalized
        self.last_move_kind = "user"
        self.next_move = self.next_move + 1

        if self.next_move > self.move_count then
            self.solved = true
            return true, true, nil, true
        end

        local auto_move = self.moves[self.next_move]
        ok, reason = rules.apply_uci(self, auto_move)
        if not ok then
            return false, "invalid_auto_move:" .. tostring(reason)
        end

        self.last_auto_move = auto_move
        self.last_move = auto_move
        self.last_move_kind = "opponent"
        self.next_move = self.next_move + 1

        if self.next_move > self.move_count then
            self.solved = true
            return true, true, auto_move, true
        end

        return true, true, auto_move, false
    end

    function Puzzle:piece_at(square_or_index)
        local index = type(square_or_index) == "number" and square_or_index or rules.square_to_index(square_or_index)
        return index and self.board[index] or nil
    end

    function Puzzle:square_for_index(index)
        return rules.index_to_square(index)
    end

    function Puzzle:board_index_for_display(x, y)
        if x < 1 or x > 8 or y < 1 or y > 8 then
            return nil
        end

        if self.player_side == "b" then
            x = 9 - x
            y = 9 - y
        end

        return (y - 1) * 8 + x
    end

    function Puzzle:display_coords_for_index(index)
        if not index or index < 1 or index > 64 then
            return nil
        end

        local row = math_floor((index - 1) / 8) + 1
        local col = index - (row - 1) * 8

        if self.player_side == "b" then
            col = 9 - col
            row = 9 - row
        end

        return col, row
    end

    function Puzzle:display_coords_for_square(square)
        return self:display_coords_for_index(rules.square_to_index(square))
    end

    function Puzzle:square_for_display(x, y)
        return rules.index_to_square(self:board_index_for_display(x, y))
    end

    function Puzzle:piece_at_display(x, y)
        local index = self:board_index_for_display(x, y)
        return index and self.board[index] or nil
    end

    function Puzzle:checked_king_display_coords()
        if self.solved or not rules.king_in_check(self, self.side_to_move) then
            return nil
        end

        local king = self.side_to_move == "w" and "K" or "k"
        for index = 1, 64 do
            if self.board[index] == king then
                return self:display_coords_for_index(index)
            end
        end

        return nil
    end

    function Puzzle:legal_targets_from_display(x, y, output)
        output = output or {}
        for key in pairs(output) do
            output[key] = nil
        end

        if self.solved then
            return output
        end

        local from_square = self:square_for_display(x, y)
        local from_piece = from_square and self:piece_at(from_square)
        if not from_piece or rules.piece_side(from_piece) ~= self.side_to_move then
            return output
        end

        local moves = rules.legal_moves_from_square(self, from_square, self._legal_move_buffer)

        for i = 1, #moves do
            local move = moves[i]
            local to_square = string_sub(move, 3, 4)
            local to_x, to_y = self:display_coords_for_square(to_square)

            if to_x and to_y then
                local capture = self:piece_at(to_square) ~= nil
                if not capture and string_lower(from_piece) == "p" then
                    local from_file = string_byte(from_square, 1)
                    local to_file = string_byte(to_square, 1)
                    capture = from_file ~= to_file
                end

                output[(to_y - 1) * 8 + to_x] = capture and "capture" or "move"
            end
        end

        return output
    end

    function Puzzle:expected_move()
        return not self.solved and self.moves[self.next_move] or nil
    end

    function Puzzle:is_solved()
        return self.solved
    end

    return Puzzle
end)()

local Session = (function()
    local backend = mod.minigame

    fassert(backend and type(backend.claim) == "function", "AuspexChess minigame backend is unavailable.")

    local Session = {}
    Session.__index = Session

    function Session.new(minigame_type, seed)
        local puzzle, reason = Puzzle.new(seed, {
            difficulty = mod:get("puzzle_difficulty") or "normal",
        })

        if not puzzle then
            return nil, reason
        end

        return setmetatable({
            puzzle = puzzle,
            _minigame_type = minigame_type,
            _claimed = false,
            _claim_id = 0,
            _commit_requested = false,
            _cancelled = false,
        }, Session)
    end

    function Session:_clear_claim()
        self._claimed = false
        self._claim_id = 0
        self._commit_requested = false
    end

    function Session:claim()
        if self._cancelled then
            return false, "cancelled"
        end

        if self._claimed then
            local state = backend:state()
            if state.active and state.claim_id == self._claim_id then
                return true, self._claim_id
            end
            self:_clear_claim()
        end

        local ok, claim_or_reason = backend:claim(self._minigame_type)
        if ok then
            self._claimed = true
            self._claim_id = claim_or_reason or 0
        end

        return ok, claim_or_reason
    end

    function Session:update()
        local state = backend:state()
        if self._cancelled then
            return state
        end

        if self._claimed and (not state.active or state.claim_id ~= self._claim_id) then
            self:_clear_claim()
            return state
        end

        if self._claimed and not self._commit_requested and self.puzzle:is_solved() then
            local ok = backend:request_commit(self._claim_id)
            if ok then
                self._commit_requested = true
            end
        end

        return state
    end

    function Session:cancel()
        if self._cancelled then
            return false
        end

        self._cancelled = true
        if not self._claimed then
            return true
        end

        local claim_id = self._claim_id
        self:_clear_claim()
        return backend:release(claim_id)
    end

    function Session:is_authoritative_complete()
        if not self._claimed then
            return false
        end

        local state = backend:state()
        return state.claim_id == self._claim_id and state.authoritative_complete == true
    end

    return Session
end)()

-- view

local ChessView = (function()
    local backend = mod.minigame
    local chess_assets = mod.chess_assets
    local UIWidget = require("scripts/managers/ui/ui_widget")

    local FONT = "proxima_nova_bold"
    local CENTER = "center_pivot"
    local CLAIM_RETRY = 0.10
    local NAV_REPEAT = 0.13

    local SQUARE_SIZE = 50
    local BOARD_TOP = -165
    local META_GAP = 34

    local PIECE_ASSET_KEYS = {
        P = "white_pawn", N = "white_knight", B = "white_bishop", R = "white_rook", Q = "white_queen", K = "white_king",
        p = "black_pawn", n = "black_knight", b = "black_bishop", r = "black_rook", q = "black_queen", k = "black_king",
    }

    local ChessView = class("AuspexChessView")
    local seed_serial = 0

    local function clamp(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
    end

    local function wrap(value, low, high)
        if value < low then return high end
        if value > high then return low end
        return value
    end

    local function set_color(color, a, r, g, b)
        color[1], color[2], color[3], color[4] = a, r, g, b
    end

    local function board_scale()
        return clamp(tonumber(mod:get("board_scale")) or 1, 0.65, 1.5)
    end

    local function wrong_move_delay()
        return clamp(tonumber(mod:get("wrong_move_delay")) or 0.50, 0.10, 2)
    end

    local function display_mode()
        return mod:get("display_mode") or "overlay"
    end

    local function current_seed()
        local t = Application and Application.time_since_launch and Application.time_since_launch() or 0
        seed_serial = seed_serial + 1
        return math.floor(t * 1000) + seed_serial
    end

    local function make_text_widget(name, size, offset, font_size, color, alignment)
        local definition = UIWidget.create_definition({
            {
                pass_type = "text",
                value = "",
                value_id = "text",
                style = {
                    font_type = FONT,
                    font_size = font_size,
                    text_color = color,
                    horizontal_alignment = "left",
                    vertical_alignment = "top",
                    text_horizontal_alignment = alignment or "left",
                    text_vertical_alignment = "top",
                    offset = { 0, 0, 2 },
                },
            },
        }, CENTER, nil, size)

        local widget = UIWidget.init(name, definition)
        widget.offset[1], widget.offset[2], widget.offset[3] = offset[1], offset[2], offset[3] or 2
        return widget
    end


    local function move_hint_visible(content)
        return content.move_preview == "move"
    end

    local function capture_hint_visible(content)
        return content.move_preview == "capture"
    end

    local function make_chess_widget(index, square)
        local dot = math.max(10, math.floor(square * 0.23 + 0.5))
        local capture_color = { 165, 28, 36, 24 }

        local definition = UIWidget.create_definition({
            {
                pass_type = "rect",
                style_id = "square",
                style = {
                    color = { 255, 150, 160, 145 },
                    offset = { 0, 0, 0 },
                },
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/hud/crosshairs/center_dot",
                style_id = "move_hint",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    color = { 165, 28, 36, 24 },
                    size = { dot, dot },
                    offset = { 0, 0, 2 },
                },
                visibility_function = move_hint_visible,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/talents/circular_frame_selected",
                style_id = "capture_hint",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    color = capture_color,
                    size = { square - 6, square - 6 },
                    offset = { 0, 0, 2 },
                },
                visibility_function = capture_hint_visible,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/base/ui_default_base",
                style_id = "piece",
                style = {
                    color = { 255, 255, 255, 255 },
                    material_values = {
                        texture_map = nil,
                        use_placeholder_texture = 0,
                    },
                    offset = { 3, 3, 3 },
                    size = { square - 6, square - 6 },
                },
                visibility_function = function(content)
                    return content.piece_ready == true
                end,
            },
            {
                pass_type = "text",
                value = "",
                value_id = "piece_text",
                style_id = "piece_text",
                style = {
                    font_type = FONT,
                    font_size = square * 0.62,
                    text_color = { 255, 245, 245, 225 },
                    text_horizontal_alignment = "center",
                    text_vertical_alignment = "center",
                    offset = { 0, -1, 3 },
                },
                visibility_function = function(content)
                    return content.piece_ready ~= true and content.piece_text and content.piece_text ~= ""
                end,
            },
        }, CENTER, nil, { square, square })

        return UIWidget.init("ac_chess_" .. index, definition)
    end

    local function make_cursor_widget(size)
        local definition = UIWidget.create_definition({
            {
                pass_type = "texture",
                value = "content/ui/materials/cursors/cursor_idle",
                style = {
                    size = { size, size },
                    color = { 255, 255, 255, 255 },
                    offset = { 0, 0, 20 },
                },
                visibility_function = function(content)
                    return content.visible == true
                end,
            },
        }, CENTER, nil, { size, size })

        local widget = UIWidget.init("ac_cursor", definition)
        widget.content.visible = false
        return widget
    end

    local function piece_matches_side(piece, side)
        if not piece then return false end
        local is_white = string.upper(piece) == piece
        return side == "w" and is_white or side == "b" and not is_white
    end

    local function side_text(side)
        return side == "b" and "BLACK" or "WHITE"
    end

    local function puzzle_progress(puzzle)
        local total = math.max(1, math.floor(puzzle.move_count / 2))
        local current = math.min(total, math.floor((puzzle.next_move - 2) / 2) + 1)
        return current, total
    end

    local function raw_navigation(x, y, t, next_nav, threshold)
        if t < next_nav then
            return 0, 0, next_nav
        end

        local dx, dy = 0, 0
        threshold = threshold or 0.45

        if math.abs(x) > math.abs(y) and math.abs(x) > threshold then
            dx = x > 0 and 1 or -1
        elseif math.abs(y) > threshold then
            dy = y > 0 and -1 or 1
        end

        if dx ~= 0 or dy ~= 0 then
            next_nav = t + NAV_REPEAT
        end

        return dx, dy, next_nav
    end

    function ChessView:init(context)
        self._minigame_type = context.minigame_type
        self._session = nil
        self._puzzle = nil

        chess_assets.load()

        local session, reason = Session.new(self._minigame_type, current_seed())
        if not session then
            mod:error("AuspexChess could not create chess session: %s", tostring(reason))
        else
            self._session = session
            self._puzzle = session.puzzle
        end

        self._scale = board_scale()
        self._chess_square = math.floor(SQUARE_SIZE * self._scale + 0.5)

        self._claimed = false
        self._next_claim = 0
        self._next_nav = 0
        self._primary_down = true
        self._cx, self._cy = 4, 4
        self._show_cursor = false
        self._from_x, self._from_y = nil, nil
        self._legal_targets = {}
        self._penalty_until = 0
        self._wrong_from_x, self._wrong_from_y = nil, nil
        self._wrong_to_x, self._wrong_to_y = nil, nil
        self._close_requested = false
        self._overlay_opened = false
        self._widgets = {}
        self._chess_widgets = {}

        self:_create_widgets()
    end

    function ChessView:destroy()
        local ui = Managers.ui
        if ui and ui:view_active(OVERLAY_VIEW_NAME) and not ui:is_view_closing(OVERLAY_VIEW_NAME) then
            local view = ui:view_instance(OVERLAY_VIEW_NAME)
            if view and view._owner == self then
                view._owner = nil
                ui:close_view(OVERLAY_VIEW_NAME)
            end
        end

        if self._session and not self._session:is_authoritative_complete() then
            self._session:cancel()
        end

        self._session = nil
        self._puzzle = nil
        self._widgets = nil
        self._chess_widgets = nil
    end

    function ChessView:request_close()
        if self._close_requested then
            return
        end

        self._close_requested = true
        backend:request_cancel()

        local ui = Managers.ui
        if not ui then
            return
        end

        if ui:view_active(OVERLAY_VIEW_NAME) and not ui:is_view_closing(OVERLAY_VIEW_NAME) then
            local view = ui:view_instance(OVERLAY_VIEW_NAME)
            if view and view._owner == self then
                view._owner = nil
                ui:close_view(OVERLAY_VIEW_NAME)
            end
        end
    end

    function ChessView:_create_widgets()
        local s = self._scale
        local widgets = self._widgets
        local square = self._chess_square
        local board = square * 8
        local x0 = -board * 0.5
        local y0 = BOARD_TOP * s

        self._meta = make_text_widget(
            "ac_meta",
            { board, 28 * s },
            { -board * 0.5, y0 - META_GAP * s, 12 },
            15 * s,
            { 255, 225, 235, 220 },
            "center"
        )
        widgets[#widgets + 1] = self._meta

        for index = 1, 64 do
            local row = math.floor((index - 1) / 8) + 1
            local col = index - (row - 1) * 8
            local widget = make_chess_widget(index, square)
            widget.offset[1] = x0 + (col - 1) * square
            widget.offset[2] = y0 + (row - 1) * square
            widget.offset[3] = 5
            self._chess_widgets[index] = widget
            widgets[#widgets + 1] = widget
        end

        self._board_x = x0
        self._board_y = y0
        self._cursor = make_cursor_widget(math.max(18, math.floor(26 * s + 0.5)))
        widgets[#widgets + 1] = self._cursor
    end

    function ChessView:_try_claim(t)
        if not self._session or self._claimed or t < self._next_claim then
            return
        end

        self._next_claim = t + CLAIM_RETRY
        local ok = self._session:claim()
        if ok then
            self._claimed = true
        end
    end


    function ChessView:_clear_selection()
        self._from_x, self._from_y = nil, nil
        for key in pairs(self._legal_targets) do
            self._legal_targets[key] = nil
        end
    end

    function ChessView:_select_square(x, y)
        self._from_x, self._from_y = x, y
        self._puzzle:legal_targets_from_display(x, y, self._legal_targets)
    end

    function ChessView:_mark_wrong(from_x, from_y, to_x, to_y, t)
        self._wrong_from_x, self._wrong_from_y = from_x, from_y
        self._wrong_to_x, self._wrong_to_y = to_x, to_y
        self._penalty_until = t + wrong_move_delay()
    end

    function ChessView:_activate_chess_square(x, y, t)
        local puzzle = self._puzzle
        if not puzzle or puzzle:is_solved() or t < self._penalty_until then
            return
        end

        local piece = puzzle:piece_at_display(x, y)
        self._cx, self._cy = x, y

        if not self._from_x then
            if piece_matches_side(piece, puzzle.player_side) then
                self:_select_square(x, y)
            end
            return
        end

        if self._from_x == x and self._from_y == y then
            self:request_close()
            return
        end

        if piece_matches_side(piece, puzzle.player_side) then
            self:_select_square(x, y)
            return
        end

        local target_index = (y - 1) * 8 + x
        if not self._legal_targets[target_index] then
            self:_clear_selection()
            return
        end

        local from_x, from_y = self._from_x, self._from_y
        local from = puzzle:square_for_display(from_x, from_y)
        local to = puzzle:square_for_display(x, y)
        local move = from .. to
        local expected = puzzle:expected_move()

        if expected and #expected == 5 and string.sub(expected, 1, 4) == move then
            move = move .. string.sub(expected, 5, 5)
        end

        local ok, correct = puzzle:submit_move(move)
        if not ok then
            mod:error("AuspexChess chess move failed: %s", tostring(correct))
            self:_mark_wrong(from_x, from_y, x, y, t)
            self:_clear_selection()
            return
        end

        if correct then
            self:_clear_selection()
        else
            self:_mark_wrong(from_x, from_y, x, y, t)
            self:_clear_selection()
        end
    end


    function ChessView:_ensure_overlay()
        if display_mode() == "auspex" then
            return
        end

        local puzzle = self._puzzle
        if self._close_requested or self._overlay_opened or not puzzle or puzzle:is_solved() then
            return
        end

        local ui = Managers.ui
        if not ui then
            return
        end

        if ui:view_active(OVERLAY_VIEW_NAME) then
            local view = ui:view_instance(OVERLAY_VIEW_NAME)
            if view and view._owner == self then
                self._overlay_opened = true
            end
            return
        end

        ui:open_view(OVERLAY_VIEW_NAME, nil, nil, nil, nil, {
            puzzle = puzzle,
            owner = self,
        })
        self._overlay_opened = true
    end

    function ChessView:_handle_input(t)
        local puzzle = self._puzzle
        if not puzzle or puzzle:is_solved() then
            return
        end

        local frontend_input = backend.frontend_input and backend:frontend_input()
        if not frontend_input then
            return
        end

        local primary = frontend_input.primary == true
        local confirm = primary and not self._primary_down
        self._primary_down = primary

        if t < self._penalty_until then
            return
        end

        local input_x = frontend_input.move_x or 0
        local input_y = frontend_input.move_y or 0
        local threshold = 0.45

        if display_mode() == "auspex" then
            local look_x, look_y = backend:take_look()
            if math.abs(look_x) > 0.0005 or math.abs(look_y) > 0.0005 then
                input_x = look_x * 220
                input_y = look_y * 220
            end
            self._show_cursor = true
        end

        local dx, dy
        dx, dy, self._next_nav = raw_navigation(input_x, input_y, t, self._next_nav, threshold)

        if dx ~= 0 or dy ~= 0 then
            self._show_cursor = true
        end
        if dx ~= 0 then
            self._cx = wrap(self._cx + dx, 1, 8)
        end
        if dy ~= 0 then
            self._cy = wrap(self._cy + dy, 1, 8)
        end
        if confirm then
            self._show_cursor = true
            self:_activate_chess_square(self._cx, self._cy, t)
        end
    end


    function ChessView:_last_move_display()
        local puzzle = self._puzzle
        local move = puzzle and puzzle.last_move
        if not move or #move < 4 then
            return nil
        end

        local from_x, from_y = puzzle:display_coords_for_square(string.sub(move, 1, 2))
        local to_x, to_y = puzzle:display_coords_for_square(string.sub(move, 3, 4))
        return from_x, from_y, to_x, to_y
    end

    function ChessView:_refresh_board(t)
        local puzzle = self._puzzle
        if not puzzle then
            return
        end

        local last_from_x, last_from_y, last_to_x, last_to_y = self:_last_move_display()
        local check_x, check_y = puzzle:checked_king_display_coords()
        local wrong_active = t < self._penalty_until

        for index = 1, 64 do
            local widget = self._chess_widgets[index]
            local row = math.floor((index - 1) / 8) + 1
            local col = index - (row - 1) * 8
            local color = widget.style.square.color

            local is_wrong = wrong_active and (
                col == self._wrong_from_x and row == self._wrong_from_y
                or col == self._wrong_to_x and row == self._wrong_to_y
            )
            local is_last_move = col == last_from_x and row == last_from_y
                or col == last_to_x and row == last_to_y

            if is_wrong then
                set_color(color, 255, 190, 74, 68)
            elseif col == self._from_x and row == self._from_y then
                set_color(color, 255, 235, 202, 72)
            elseif self._show_cursor and col == self._cx and row == self._cy then
                set_color(color, 255, 112, 174, 104)
            elseif col == check_x and row == check_y then
                set_color(color, 255, 202, 86, 78)
            elseif is_last_move then
                set_color(color, 255, 126, 167, 177)
            elseif (col + row) % 2 == 0 then
                set_color(color, 255, 212, 220, 202)
            else
                set_color(color, 255, 136, 151, 126)
            end

            widget.content.move_preview = self._legal_targets[index]

            local piece = puzzle:piece_at_display(col, row)
            local key = piece and PIECE_ASSET_KEYS[piece]
            local texture = key and chess_assets.texture(key) or nil

            widget.content.piece_text = piece or ""
            widget.content.piece_ready = texture ~= nil

            if piece then
                local text_color = widget.style.piece_text.text_color
                if string.upper(piece) == piece then
                    set_color(text_color, 255, 248, 246, 225)
                else
                    set_color(text_color, 255, 0, 0, 0)
                end
            end

            if texture then
                widget.style.piece.material_values.texture_map = texture
            end
        end

        local cursor = self._cursor
        if cursor then
            local visible = display_mode() == "auspex" and not puzzle:is_solved()
            cursor.content.visible = visible

            if visible then
                local square = self._chess_square
                cursor.offset[1] = self._board_x + (self._cx - 0.5) * square
                cursor.offset[2] = self._board_y + (self._cy - 0.5) * square
                cursor.offset[3] = 20
            end
        end
    end

    function ChessView:_refresh_text()
        local puzzle = self._puzzle
        if not puzzle then
            self._meta.content.text = ""
            return
        end

        local current, total = puzzle_progress(puzzle)
        self._meta.content.text = string.format(
            "%s   •   MOVE %d/%d   •   %s TO MOVE",
            string.upper(puzzle.difficulty or "normal"),
            current,
            total,
            side_text(puzzle.player_side)
        )
    end

    function ChessView:update(dt, t)
        self:_try_claim(t)
        self:_ensure_overlay()

        if display_mode() == "auspex" then
            self:_handle_input(t)
        end

        local state = self._session and self._session:update() or backend:state()

        self:_refresh_board(t)
        self:_refresh_text()

        if state.authoritative_complete then
            self._close_requested = true
        end
    end

    function ChessView:draw_widgets(dt, t, input_service, ui_renderer)
        local widgets = self._widgets
        for i = 1, #widgets do
            UIWidget.draw(widgets[i], ui_renderer)
        end
    end

    return ChessView
end)()



-- overlay view

local ChessOverlayView = (function()
    require("scripts/ui/views/base_view")

    local UIWorkspaceSettings = require("scripts/settings/ui/ui_workspace_settings")
    local UIWidget = require("scripts/managers/ui/ui_widget")

    local VIEW_NAME = OVERLAY_VIEW_NAME
    local FONT = "proxima_nova_bold"
    local NAV_REPEAT = 0.13

    local SQUARE_SIZE = 50
    local BOARD_TOP = -165
    local META_GAP = 34

    local PIECE_ASSET_KEYS = {
        P = "white_pawn", N = "white_knight", B = "white_bishop", R = "white_rook", Q = "white_queen", K = "white_king",
        p = "black_pawn", n = "black_knight", b = "black_bishop", r = "black_rook", q = "black_queen", k = "black_king",
    }

    local function clamp(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
    end

    local function wrap(value, low, high)
        if value < low then return high end
        if value > high then return low end
        return value
    end

    local function set_color(color, a, r, g, b)
        color[1], color[2], color[3], color[4] = a, r, g, b
    end

    local function board_scale()
        return clamp(tonumber(mod:get("board_scale")) or 1, 0.65, 1.5)
    end

    local function wrong_move_delay()
        return clamp(tonumber(mod:get("wrong_move_delay")) or 0.50, 0.10, 2)
    end

    local function text_style(size, color, alignment)
        return {
            font_type = FONT,
            font_size = size,
            text_color = color,
            text_horizontal_alignment = alignment or "center",
            text_vertical_alignment = "top",
            offset = { 0, 0, 2 },
        }
    end

    local function piece_matches_side(piece, side)
        if not piece then return false end
        local is_white = string.upper(piece) == piece
        return side == "w" and is_white or side == "b" and not is_white
    end

    local function side_text(side)
        return side == "b" and "BLACK" or "WHITE"
    end

    local function puzzle_progress(puzzle)
        local total = math.max(1, math.floor(puzzle.move_count / 2))
        local current = math.min(total, math.floor((puzzle.next_move - 2) / 2) + 1)
        return current, total
    end

    -- widgets

    local function move_hint_visible(content)
        return content.move_preview == "move"
    end

    local function capture_hint_visible(content)
        return content.move_preview == "capture"
    end

    local function chess_square_definition(scenegraph_id, square)
        local dot = math.max(10, math.floor(square * 0.23 + 0.5))
        local capture_color = { 165, 28, 36, 24 }

        return UIWidget.create_definition({
            {
                pass_type = "hotspot",
                content_id = "hotspot",
            },
            {
                pass_type = "rect",
                style_id = "square",
                style = {
                    color = { 255, 150, 160, 145 },
                    offset = { 0, 0, 0 },
                },
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/hud/crosshairs/center_dot",
                style_id = "move_hint",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    color = { 165, 28, 36, 24 },
                    size = { dot, dot },
                    offset = { 0, 0, 2 },
                },
                visibility_function = move_hint_visible,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/talents/circular_frame_selected",
                style_id = "capture_hint",
                style = {
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    color = capture_color,
                    size = { square - 6, square - 6 },
                    offset = { 0, 0, 2 },
                },
                visibility_function = capture_hint_visible,
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/base/ui_default_base",
                style_id = "piece",
                style = {
                    color = { 255, 255, 255, 255 },
                    material_values = {
                        texture_map = nil,
                        use_placeholder_texture = 0,
                    },
                    offset = { 3, 3, 3 },
                    size = { square - 6, square - 6 },
                },
                visibility_function = function(content)
                    return content.piece_ready == true
                end,
            },
            {
                pass_type = "text",
                value = "",
                value_id = "piece_text",
                style_id = "piece_text",
                style = {
                    font_type = FONT,
                    font_size = square * 0.62,
                    text_color = { 255, 245, 245, 225 },
                    text_horizontal_alignment = "center",
                    text_vertical_alignment = "center",
                    offset = { 0, -1, 3 },
                },
                visibility_function = function(content)
                    return content.piece_ready ~= true and content.piece_text and content.piece_text ~= ""
                end,
            },
        }, scenegraph_id)
    end

    local function build_definitions(scale)
        local square = math.floor(SQUARE_SIZE * scale + 0.5)
        local board = square * 8
        local x0 = -board * 0.5
        local y0 = BOARD_TOP * scale

        local scenegraph = {
            screen = UIWorkspaceSettings.screen,
            meta = {
                parent = "screen",
                horizontal_alignment = "center",
                vertical_alignment = "center",
                size = { board, 28 * scale },
                position = { 0, y0 - META_GAP * scale, 12 },
            },
        }

        for row = 1, 8 do
            for col = 1, 8 do
                local index = (row - 1) * 8 + col
                scenegraph["chess_square_" .. index] = {
                    parent = "screen",
                    horizontal_alignment = "center",
                    vertical_alignment = "center",
                    size = { square, square },
                    position = { x0 + (col - 1) * square, y0 + (row - 1) * square, 5 },
                }
            end
        end

        local widgets = {
            meta = UIWidget.create_definition({
                {
                    pass_type = "text",
                    value = "",
                    value_id = "text",
                    style = text_style(15 * scale, { 255, 225, 235, 220 }, "center"),
                },
            }, "meta"),
        }

        for i = 1, 64 do
            widgets["chess_square_" .. i] = chess_square_definition("chess_square_" .. i, square)
        end

        return {
            scenegraph_definition = scenegraph,
            widget_definitions = widgets,
        }
    end

    local ChessOverlayView = class("AuspexChessOverlayView", "BaseView")

    function ChessOverlayView:init(view_settings, context)
        self._puzzle = context and context.puzzle
        self._owner = context and context.owner
        self._debug = context and context.debug == true
        self._scale = board_scale()
        self._no_cursor = false

        chess_assets.load()

        local definitions = build_definitions(self._scale)
        ChessOverlayView.super.init(self, definitions, view_settings, context)

        self._pass_input = false
        self._pass_draw = true
        self._legal_targets = {}
        self:set_puzzle(self._puzzle)
    end

    function ChessOverlayView:set_puzzle(puzzle)
        self._puzzle = puzzle
        self._cx, self._cy = 4, 4
        self._show_cursor = false
        self._from_x, self._from_y = nil, nil
        table.clear(self._legal_targets)
        self._next_nav = 0
        self._keyboard_confirm_down = false
        self._penalty_until = 0
        self._wrong_from_x, self._wrong_from_y = nil, nil
        self._wrong_to_x, self._wrong_to_y = nil, nil
    end

    local function key_down(name)
        if not Keyboard or not Keyboard.button or not Keyboard.button_index then
            return false
        end

        local value = Keyboard.button(Keyboard.button_index(name))
        return value == true or type(value) == "number" and value > 0
    end

    local function navigation(input_service, t, next_allowed)
        if t < next_allowed then
            return 0, 0, next_allowed
        end

        local dx, dy = 0, 0

        if key_down("a") or input_service:get("navigate_left_continuous") then
            dx = -1
        elseif key_down("d") or input_service:get("navigate_right_continuous") then
            dx = 1
        elseif key_down("w") or input_service:get("navigate_up_continuous") then
            dy = -1
        elseif key_down("s") or input_service:get("navigate_down_continuous") then
            dy = 1
        end

        if dx ~= 0 or dy ~= 0 then
            next_allowed = t + NAV_REPEAT
        end

        return dx, dy, next_allowed
    end

    -- input

    function ChessOverlayView:_clear_selection()
        self._from_x, self._from_y = nil, nil
        for key in pairs(self._legal_targets) do
            self._legal_targets[key] = nil
        end
    end

    function ChessOverlayView:_request_exit()
        local owner = self._owner
        if owner and owner.request_close then
            owner:request_close()
            return
        end

        local ui = Managers.ui
        if ui and ui:view_active(VIEW_NAME) and not ui:is_view_closing(VIEW_NAME) then
            ui:close_view(VIEW_NAME)
        end
    end

    function ChessOverlayView:_select_square(x, y)
        self._from_x, self._from_y = x, y
        self._puzzle:legal_targets_from_display(x, y, self._legal_targets)
    end

    function ChessOverlayView:_mark_wrong(from_x, from_y, to_x, to_y, t)
        self._wrong_from_x, self._wrong_from_y = from_x, from_y
        self._wrong_to_x, self._wrong_to_y = to_x, to_y
        self._penalty_until = t + wrong_move_delay()
    end

    function ChessOverlayView:_activate_chess_square(x, y, t)
        local puzzle = self._puzzle
        if not puzzle or puzzle:is_solved() or t < self._penalty_until then
            return
        end

        local piece = puzzle:piece_at_display(x, y)
        self._cx, self._cy = x, y

        if not self._from_x then
            if piece_matches_side(piece, puzzle.player_side) then
                self:_select_square(x, y)
            end
            return
        end

        if self._from_x == x and self._from_y == y then
            self:_request_exit()
            return
        end

        if piece_matches_side(piece, puzzle.player_side) then
            self:_select_square(x, y)
            return
        end

        local target_index = (y - 1) * 8 + x
        if not self._legal_targets[target_index] then
            self:_clear_selection()
            return
        end

        local from_x, from_y = self._from_x, self._from_y
        local from = puzzle:square_for_display(from_x, from_y)
        local to = puzzle:square_for_display(x, y)
        local move = from .. to
        local expected = puzzle:expected_move()

        if expected and #expected == 5 and string.sub(expected, 1, 4) == move then
            move = move .. string.sub(expected, 5, 5)
        end

        local ok, correct = puzzle:submit_move(move)
        if not ok then
            mod:error("AuspexChess chess move failed: %s", tostring(correct))
            self:_mark_wrong(from_x, from_y, x, y, t)
            self:_clear_selection()
            return
        end

        if correct then
            self:_clear_selection()
        else
            self:_mark_wrong(from_x, from_y, x, y, t)
            self:_clear_selection()
        end
    end

    function ChessOverlayView:_handle_chess_hotspots(input_service, t)
        local puzzle = self._puzzle
        if not puzzle or puzzle:is_solved() or t < self._penalty_until or not input_service:get("left_pressed") then
            return false
        end

        for index = 1, 64 do
            local widget = self._widgets_by_name and self._widgets_by_name["chess_square_" .. index]
            local hotspot = widget and widget.content and widget.content.hotspot

            if hotspot and hotspot.is_hover then
                local row = math.floor((index - 1) / 8) + 1
                local col = index - (row - 1) * 8
                self._show_cursor = false
                self:_activate_chess_square(col, row, t)
                return true
            end
        end

        return false
    end

    function ChessOverlayView:_handle_keyboard(input_service, t)
        local puzzle = self._puzzle
        if not puzzle or puzzle:is_solved() then
            return
        end

        local confirm_down = key_down("space") or key_down("enter")
        local confirm = confirm_down and not self._keyboard_confirm_down
        self._keyboard_confirm_down = confirm_down

        if t < self._penalty_until then
            return
        end

        local dx, dy
        dx, dy, self._next_nav = navigation(input_service, t, self._next_nav)

        if dx ~= 0 or dy ~= 0 then
            self._show_cursor = true
        end
        if dx ~= 0 then
            self._cx = wrap(self._cx + dx, 1, 8)
        end
        if dy ~= 0 then
            self._cy = wrap(self._cy + dy, 1, 8)
        end
        if confirm then
            self._show_cursor = true
            self:_activate_chess_square(self._cx, self._cy, t)
        end
    end

    function ChessOverlayView:_handle_input(input_service, dt, t)
        if input_service:get("back") then
            self:_request_exit()
            return
        end

        local mouse_handled = self:_handle_chess_hotspots(input_service, t)
        if not mouse_handled then
            self:_handle_keyboard(input_service, t)
        end
    end

    -- rendering

    function ChessOverlayView:_last_move_display()
        local puzzle = self._puzzle
        local move = puzzle and puzzle.last_move
        if not move or #move < 4 then
            return nil
        end

        local from_x, from_y = puzzle:display_coords_for_square(string.sub(move, 1, 2))
        local to_x, to_y = puzzle:display_coords_for_square(string.sub(move, 3, 4))
        return from_x, from_y, to_x, to_y
    end

    function ChessOverlayView:_refresh_board(t)
        local puzzle = self._puzzle
        if not puzzle or not self._widgets_by_name then
            return
        end

        local last_from_x, last_from_y, last_to_x, last_to_y = self:_last_move_display()
        local check_x, check_y = puzzle:checked_king_display_coords()
        local wrong_active = t < self._penalty_until

        for index = 1, 64 do
            local widget = self._widgets_by_name["chess_square_" .. index]
            local row = math.floor((index - 1) / 8) + 1
            local col = index - (row - 1) * 8
            local color = widget.style.square.color
            local hotspot = widget.content.hotspot

            local is_wrong = wrong_active and (
                col == self._wrong_from_x and row == self._wrong_from_y
                or col == self._wrong_to_x and row == self._wrong_to_y
            )
            local is_last_move = col == last_from_x and row == last_from_y
                or col == last_to_x and row == last_to_y

            if is_wrong then
                set_color(color, 255, 190, 74, 68)
            elseif col == self._from_x and row == self._from_y then
                set_color(color, 255, 235, 202, 72)
            elseif self._show_cursor and col == self._cx and row == self._cy then
                set_color(color, 255, 112, 174, 104)
            elseif hotspot and hotspot.is_hover then
                set_color(color, 255, 198, 184, 104)
            elseif col == check_x and row == check_y then
                set_color(color, 255, 202, 86, 78)
            elseif is_last_move then
                set_color(color, 255, 126, 167, 177)
            elseif (col + row) % 2 == 0 then
                set_color(color, 255, 212, 220, 202)
            else
                set_color(color, 255, 136, 151, 126)
            end

            widget.content.move_preview = self._legal_targets[index]

            local piece = puzzle:piece_at_display(col, row)
            local key = piece and PIECE_ASSET_KEYS[piece]
            local texture = key and chess_assets.texture(key) or nil

            widget.content.piece_text = piece or ""
            widget.content.piece_ready = texture ~= nil

            if piece then
                local text_color = widget.style.piece_text.text_color
                if string.upper(piece) == piece then
                    set_color(text_color, 255, 248, 246, 225)
                else
                    set_color(text_color, 255, 0, 0, 0)
                end
            end

            if texture then
                widget.style.piece.material_values.texture_map = texture
            end

        end
    end

    function ChessOverlayView:_refresh_text()
        local puzzle = self._puzzle
        if not puzzle or not self._widgets_by_name then
            return
        end

        local current, total = puzzle_progress(puzzle)
        self._widgets_by_name.meta.content.text = string.format(
            "%s   •   MOVE %d/%d   •   %s TO MOVE",
            string.upper(puzzle.difficulty or "normal"),
            current,
            total,
            side_text(puzzle.player_side)
        )
    end

    function ChessOverlayView:update(dt, t, input_service)
        local pass_input, pass_draw = ChessOverlayView.super.update(self, dt, t, input_service)

        self:_refresh_board(t)
        self:_refresh_text()

        local ui = Managers.ui
        if self._puzzle and self._puzzle:is_solved() and ui and ui:view_active(VIEW_NAME) and not ui:is_view_closing(VIEW_NAME) then
            ui:close_view(VIEW_NAME)
        end

        return pass_input, pass_draw
    end

    return ChessOverlayView
end)()

return {
    assets = chess_assets,
    Puzzle = Puzzle,
    View = ChessView,
    OverlayView = ChessOverlayView,
}
