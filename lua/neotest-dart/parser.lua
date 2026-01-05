local utils = require('neotest-dart.utils')
local async = require('neotest.async')

local M = {}

local function get_test_names_by_ids(parsed_jsons)
  local map = {}

  for _, line in ipairs(parsed_jsons) do
    if line.test then
      map[line.test.id] = line.test.name
    end
  end
  return map
end

local dart_to_neotest_status_map = {
  success = 'passed',
  error = 'failed',
  failure = 'failed',
}

---@param test_result table
---@returns string
local function construct_neotest_status(test_result)
  if test_result.skipped then
    return 'skipped'
  end
  if test_result.status == nil then
    return 'running'
  end
  return test_result.status
end

--- Aggressively reconstructs JSON from corrupted/truncated output
---@param lines string[]
---@return string[]
local function reconstruct_json_lines(lines)
  -- Concatenate everything first - this handles severe truncation
  local full_text = table.concat(lines, '')

  local reconstructed = {}
  local i = 1

  while i <= #full_text do
    -- Find start of next JSON object
    local start = full_text:find('{', i, true)
    if not start then
      break
    end

    -- Extract complete JSON by tracking brace depth
    local brace_count = 0
    local in_string = false
    local escape_next = false
    local obj_end = nil

    for j = start, #full_text do
      local char = full_text:sub(j, j)

      if escape_next then
        escape_next = false
      elseif char == '\\' and in_string then
        escape_next = true
      elseif char == '"' then
        in_string = not in_string
      elseif not in_string then
        if char == '{' then
          brace_count = brace_count + 1
        elseif char == '}' then
          brace_count = brace_count - 1
          if brace_count == 0 then
            obj_end = j
            break
          end
        end
      end
    end

    if obj_end then
      local json_str = full_text:sub(start, obj_end)
      -- Validate it's parseable JSON
      local ok, parsed = pcall(vim.json.decode, json_str, { luanil = { object = true } })
      if ok then
        table.insert(reconstructed, json_str)
      end
      i = obj_end + 1
    else
      -- Couldn't find closing brace, skip this opening brace
      i = start + 1
    end
  end

  return reconstructed
end

--- Collects test output to single table where test information is accessible
--- by test name. Handles severely corrupted/truncated output.
---@param lines string[]
---@return table, table
local function marshal_test_results(lines)
  local tests = {}
  local parsed_jsons = {}
  local unparsable_lines = {}

  -- Reconstruct JSON from potentially corrupted output
  local json_lines = reconstruct_json_lines(lines)

  -- Parse each reconstructed JSON and deduplicate
  local seen_objects = {}

  for _, line in ipairs(json_lines) do
    if line ~= '' then
      local ok, parsed = pcall(vim.json.decode, line, { luanil = { object = true } })
      if ok then
        -- Create unique fingerprint for deduplication
        local fingerprint = nil

        if parsed.testID and parsed.type then
          -- For test results, use testID + type + result
          fingerprint = string.format(
            'testID:%d:type:%s:result:%s:time:%s',
            parsed.testID,
            parsed.type,
            parsed.result or 'none',
            parsed.time or 0
          )
        elseif parsed.test and parsed.test.id then
          -- For test definitions, use test id + name
          fingerprint = string.format('test:id:%d:name:%s', parsed.test.id, parsed.test.name or '')
        elseif parsed.group and parsed.group.id then
          -- For groups, use group id
          fingerprint =
            string.format('group:id:%d:name:%s', parsed.group.id, parsed.group.name or '')
        elseif parsed.suite and parsed.suite.id ~= nil then
          -- For suites, use suite id
          fingerprint = string.format('suite:id:%d', parsed.suite.id)
        elseif parsed.type == 'allSuites' or parsed.type == 'done' or parsed.type == 'start' then
          -- For events, use type + time
          fingerprint = string.format('event:%s:%d', parsed.type, parsed.time or 0)
        end

        -- Only add if we haven't seen this exact object before
        if fingerprint and not seen_objects[fingerprint] then
          seen_objects[fingerprint] = true
          table.insert(parsed_jsons, parsed)
        elseif not fingerprint then
          -- If we can't create a fingerprint, add it anyway (rare edge case)
          table.insert(parsed_jsons, parsed)
        end
      end
    end
  end

  -- Collect any non-JSON content as unparsable
  for _, line in ipairs(lines) do
    if line ~= '' and not line:match('^%s*{') and not line:match('}%s*$') then
      table.insert(unparsable_lines, line)
    end
  end

  local test_names_by_ids = get_test_names_by_ids(parsed_jsons)

  for _, json in ipairs(parsed_jsons) do
    if json.testID then
      local test_name = test_names_by_ids[json.testID]
      if test_name then
        local test_data = tests[test_name] or {}
        if json.result then
          test_data.status = dart_to_neotest_status_map[json.result]
        end
        if json.message then
          if test_data.message == nil then
            test_data.message = json.message
          else
            -- Concatenate all messages for the test
            test_data.message = test_data.message .. '\n' .. json.message
          end
        end
        if json.error then
          test_data.error = json.error
          test_data.stack_trace = json.stackTrace
        end
        test_data.skipped = json.skipped
        test_data.time = json.time
        tests[test_name] = test_data
      end
    end
  end
  return tests, unparsable_lines
end

local function highlight_as_error(message)
  if message == nil then
    return nil
  end
  return message:gsub('^', '[31m'):gsub('$', '[0m')
end

---@returns string formated duration
local function format_duration(milliseconds)
  local seconds = milliseconds / 1000
  if seconds > 0 then
    return seconds .. 's.'
  end
  return milliseconds .. 'ms.'
end

---@param output string
---@return string
local function sanitize_output(output)
  if not output then
    return output
  end
  return output:gsub('\r', '')
end

---@param error string
---@return string
local function format_error(error)
  -- remove file path from the beggining
  error = error:gsub("^'file:.*dart': (.*)$", '%1')
  return highlight_as_error(error)
end

---@param test_result table dart test result
---@param unparsable_lines table lines that was not possible to convert to json
---@returns string path to output file
local function prepare_neotest_output(test_result, unparsable_lines)
  local fname = async.fn.tempname()
  local file_output = {}
  if unparsable_lines then
    for _, line in ipairs(unparsable_lines) do
      local sanitized = sanitize_output(line)
      table.insert(file_output, sanitized)
    end
  end
  local message = test_result.message
  if message then
    message = highlight_as_error(message)
    local messages = vim.split(message, '\n')
    table.insert(file_output, messages)
  end
  if test_result.error then
    local error = format_error(test_result.error)
    table.insert(file_output, error)
  end
  if test_result.stack_trace then
    local stack_trace = highlight_as_error(test_result.stack_trace)
    local stack_trace_lines = vim.split(stack_trace, '\n')
    table.insert(file_output, '')
    table.insert(file_output, stack_trace_lines)
  end
  if test_result.time then
    local test_time = format_duration(test_result.time)
    table.insert(file_output, 'Elapsed: ' .. test_time)
  end
  local flatten = vim.tbl_flatten(file_output)
  vim.fn.writefile(flatten, fname, 'b')
  return fname
end

local function construct_diagnostic_errors(test_result)
  local line
  local message
  if test_result.status == 'failed' then
    if test_result.message then
      local _, _, str = test_result.message:find('test.dart line (%d+)')
      if str then
        line = tonumber(str) - 1
      end
      message = test_result.message
    end
    if test_result.error then
      if test_result.stack_trace then
        local _, _, str = test_result.stack_trace:find('test.dart (%d+):')
        if str then
          line = tonumber(str) - 1
        end
      end
      if not message then
        message = test_result.error
      end
    end
    if message then
      message = message
        :gsub(
          '══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════',
          ''
        )
        :gsub('The following TestFailure was thrown running a test:', '')
      return { { message = message, line = line } }
    end
  end
end

M.parse_lines = function(tree, lines, outline)
  local tests, unparsable_lines = marshal_test_results(lines)
  local results = {}
  for _, node in tree:iter_nodes() do
    local value = node:data()
    if value.type == 'test' then
      local test_name = utils.construct_test_name(value, outline)
      local test_result = tests[test_name]
      if test_result then
        local neotest_result = {
          status = construct_neotest_status(test_result),
          short = highlight_as_error(test_result.message),
          output = prepare_neotest_output(test_result, unparsable_lines),
          errors = construct_diagnostic_errors(test_result),
        }
        results[value.id] = neotest_result
      end
    end
  end
  return results
end

return M
