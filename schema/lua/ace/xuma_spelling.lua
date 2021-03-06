-- xuma_spelling.lua

--[[
单字的字根拆分三重注解直接利用 simplifier 通过预制的 OpenCC 词库查到。
问题：这个方法，词组只能显示每个单字的注解，需要进行简化合并处理，仅显示词组编
码和对应字根。
计划：用 Lua 处理词组注解。

实现障碍：simplifier 返回的类型，无法修改其注释。
   https://github.com/hchunhui/librime-lua/issues/16
一个思路：show_in_commet: false
   然后读取 cand.text 修改后作为注释显示，问题是无法直接将 cand.text 改回。
   理论上只能用 Candidate() 生成简单类型候选。

现在的方案：完全弃用 simplifier + OpenCC，单字和词组都用 Lua 处理。

注解数据来源与 OpenCC 方法相同，编成伪方案的伪词典，通过写入主方案的
schema/dependencies 来让 rime 编译为反查库 *.reverse.bin，最后通过 Lua 的反查
函数查询。

词组中有的取码单字可能没有注解数据，这类词组不作注解。

Todo: 如果要为自造词添加编码注释，其中的单字存在一字多码的情况，先捕获全部再确
定全码，最后提取词组编码。
。
注意特殊单字：八个八卦名，排除其特殊符号编码 dl?g.

Handle multibye string in Lua:
  https://stackoverflow.com/questions/9003747/splitting-a-multibyte-string-in-lua

lua_filter 如何判断 cand 是否来自反查或当前是否处于反查状态？
  https://github.com/hchunhui/librime-lua/issues/18
--]]

local basic = require('ace/lib/basic')
local map = basic.map
local index = basic.index
local utf8chars = basic.utf8chars
local matchstr = basic.matchstr

local function xform(input)
  -- From: "[spelling,code_code...,pinyin_pinyin...]"
  -- To: "〔 spelling · code code ... · pinyin pinyin ... 〕"
  if input == "" then return "" end
  input = input:gsub('%[', '〔 ')
  input = input:gsub('%]', ' 〕')
  input = input:gsub('{', '<')
  input = input:gsub('}', '>')
  input = input:gsub('_', ' ')
  input = input:gsub(',', ' · ')
  return input
end

local function subspelling(str, ...)
  -- Handle spellings like "{于下}{四点}丶"(求) where some radicals are
  -- represented by multiple characters.
  local first, last = ...
  if not first then return str end
  local radicals = {}
  local s = str
  s = s:gsub('{', ' {')
  s = s:gsub('}', '} ')
  for seg in s:gmatch('%S+') do
    if seg:find('^{.+}$') then
      table.insert(radicals, seg)
    else
      for pos, code in utf8.codes(seg) do
        table.insert(radicals, utf8.char(code))
      end
    end
  end
  return table.concat{ table.unpack(radicals, first, last) }
end

local function lookup(db)
  return function (str)
    return db:lookup(str)
  end
end

local function parse_spll(str)
  local s = string.gsub(str, ',.*', '')
  return string.gsub(s, '^%[', '')
end

local function spell_phrase(s, spll_rvdb)
  local chars = utf8chars(s)
  local rvlk_results
  if #chars == 2 or #chars == 3 then
    rvlk_results = map(chars, lookup(spll_rvdb))
  else
    rvlk_results = map({chars[1], chars[2], chars[3], chars[#chars]},
        lookup(spll_rvdb))
  end
  if index(rvlk_results, '') then return '' end
  local spellings = map(rvlk_results, parse_spll)
  local sup = '◇'
  if #chars == 2 then
    return subspelling(spellings[1] .. sup, 1, 2) ..
           subspelling(spellings[2] .. sup, 1, 2)
  elseif #chars == 3 then
    return subspelling(spellings[1], 1, 1) ..
           subspelling(spellings[2], 1, 1) ..
           subspelling(spellings[3] .. sup, 1, 2)
  else
    return subspelling(spellings[1], 1, 1) ..
           subspelling(spellings[2], 1, 1) ..
           subspelling(spellings[3], 1, 1) ..
           subspelling(spellings[4], 1, 1)
  end
end

local function get_tricomment(cand, env)
  local ctext = cand.text
  if utf8.len(ctext) == 1 then
    local spll_raw = env.spll_rvdb:lookup(ctext)
    if spll_raw ~= '' then
      if env.engine.context:get_option("xmsp_hide_pinyin") then
        return xform(spll_raw:gsub('%[(.-,.-),.+%]', '[%1]'))
      else
        return xform(spll_raw)
      end
    end
  else
    local spelling = spell_phrase(ctext, env.spll_rvdb)
    if spelling ~= '' then
      spelling = spelling:gsub('{(.-)}', '<%1>')
      -- 候选是否为自造词，可通过在固态词典中查询其编码来确定。
      local code = env.code_rvdb:lookup(ctext)
      if code ~= '' then
        -- 按长度排列多个编码。
        code = matchstr(code, '%a+')
        table.sort(code, function(i, j) return i:len() < j:len() end)
        code = table.concat(code, ' ')
        return '〔 ' .. spelling .. ' · ' .. code .. ' 〕'
      else
        return '〈 ' .. spelling .. ' 〉'
      end
    end
  end
  return ''
end

local function filter(input, env)
  if env.engine.context:get_option("xuma_spelling") then
    for cand in input:iter() do
      --[[
      用户有时需要通过拼音反查简化字并显示三重注解，但 luna_pinyin 的简化字排
      序不合理且靠后。开启 simplification 是一个办法，但是 simplifier 会强制覆
      盖注释，所以为了同时能显示三重注解，只能重新生成一个简单类型候选，并代替
      原候选。
      Todo: 测试在对 simplifier 定义 tips: none 的条件下，用 cand.text 和
      cand:get_genuine().text 分别读到什么值。若分别读到转换前后的候选，则可以
      仅修改 comment 而不用生成简单类型候选来代替原始候选。这样做的问题是关闭
      xuma_spelling 时就不显示 tips 了。
      --]]
      if cand.type == 'simplified' and env.name_space == 'xmsp_for_rvlk' then
        local comment = get_tricomment(cand, env) .. cand.comment
        yield(Candidate("simp_rvlk", cand.start, cand._end, cand.text, comment))
      else
        local add_comment = ''
        if cand.type == 'punct' then
          add_comment = env.code_rvdb:lookup(cand.text)
        elseif cand.type ~= 'sentence' then
          add_comment = get_tricomment(cand, env)
        end
        if add_comment ~= '' then
          -- 混输和反查中的非 completion 类型，原注释为空或主词典的编码。
          -- 为免重复冗长，直接以新增注释替换之。前提是后者非空。
          if cand.type ~= 'completion' and (
              (env.name_space == 'xmsp' and env.is_mixtyping) or
              (env.name_space == 'xmsp_for_rvlk')
              ) then
            cand.comment = add_comment
          else
            cand.comment = add_comment .. cand.comment
          end
        end
        yield(cand)
      end
    end
  else
    for cand in input:iter() do yield(cand) end
  end
end

local function init(env)
  local config = env.engine.schema.config
  local spll_rvdb = config:get_string('lua_reverse_db/spelling')
  local code_rvdb = config:get_string('lua_reverse_db/code')
  local abc_extags_size = config:get_list_size('abc_segmentor/extra_tags')
  env.spll_rvdb = ReverseDb('build/' .. spll_rvdb .. '.reverse.bin')
  env.code_rvdb = ReverseDb('build/' .. code_rvdb .. '.reverse.bin')
  env.is_mixtyping = abc_extags_size > 0
end

return { init = init, func = filter }
