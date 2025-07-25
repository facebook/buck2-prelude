%% Copyright (c) Meta Platforms, Inc. and affiliates.
%%
%% This source code is licensed under both the MIT license found in the
%% LICENSE-MIT file in the root directory of this source tree and the Apache
%% License, Version 2.0 found in the LICENSE-APACHE file in the root directory
%% of this source tree.

%% @format
-module(ct_runner).
-moduledoc """
Simple gen_server that will run the the test and
communicates the result to the test runner.
""".
-eqwalizer(ignore).

-behavior(gen_server).

-export([start_link/1]).
-include_lib("common/include/buck_ct_records.hrl").
-include_lib("kernel/include/logger.hrl").
-define(raw_file_access, prim_file).

-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export([
    start_test_node/6,
    start_test_node/7,
    cookie/0,
    generate_arg_tuple/2,
    project_root/0
]).

-type opt() ::
    {packet, N :: 1 | 2 | 4}
    | stream
    | {line, L :: non_neg_integer()}
    | {cd, Dir :: string() | binary()}
    | {env, Env :: [{Name :: os:env_var_name(), Val :: os:env_var_value() | false}]}
    | {args, [string() | binary()]}
    | {arg0, string() | binary()}
    | exit_status
    | use_stdio
    | nouse_stdio
    | stderr_to_stdout
    | in
    | out
    | binary
    | eof
    | {parallelism, Boolean :: boolean()}
    | hide
    | {busy_limits_port, {non_neg_integer(), non_neg_integer()} | disabled}
    | {busy_limits_msgq, {non_neg_integer(), non_neg_integer()} | disabled}.

-type port_settings() :: [opt()].

-export_type([port_settings/0]).

-define(DEFAULT_LAUNCH_PORT_OPTIONS, [exit_status, nouse_stdio]).

%% Starts and monitor (through an erlang port) a ct_run.
%% Reports the result of the execution to the test runner.
-spec start_link(#test_env{}) -> {ok, pid()} | {error, term()}.
start_link(#test_env{} = TestEnv) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [TestEnv], []).

init([#test_env{} = TestEnv]) ->
    process_flag(trap_exit, true),
    PortEpmd = epmd_manager:get_port(),
    {ok, #{test_env => TestEnv, std_out => []}, {continue, {run, PortEpmd}}}.

handle_continue(
    {run, PortEpmd},
    #{test_env := TestEnv} = State
) ->
    try run_test(TestEnv, PortEpmd) of
        Port -> {noreply, State#{port => Port}}
    catch
        Class:Reason:Stack ->
            ErrorMsg = io_lib:format("Ct Runner failed to launch test due to ~ts\n", [
                erl_error:format_exception(Class, Reason, Stack)
            ]),
            ?LOG_ERROR(ErrorMsg),
            test_runner:mark_failure(ErrorMsg),
            {stop, ct_runner_failed, State}
    end.

handle_info(
    {Port, {exit_status, ExitStatus}},
    #{port := Port} = State
) ->
    case ExitStatus of
        0 ->
            ResultMsg = "ct_runner finished successfully with exit status 0",
            ?LOG_DEBUG(ResultMsg),
            test_runner:mark_success(ResultMsg);
        _ ->
            ErrorMsg =
                case ExitStatus of
                    137 ->
                        "ct runner killed by SIGKILL (exit code 137), likely due to running out of memory. Check https://fburl.com/wiki/01s5fnom for information about memory limits for tests";
                    _ ->
                        unicode:characters_to_list(
                            io_lib:format("ct run exited with status exit ~p", [
                                ExitStatus
                            ])
                        )
                end,
            ?LOG_ERROR(ErrorMsg),
            test_runner:mark_failure(ErrorMsg)
    end,
    {stop, {ct_run_finished, ExitStatus}, State};
handle_info({_Port, {data, Data}}, #{std_out := StdOut} = State) ->
    ?LOG_DEBUG("~s", [Data]),
    {noreply, State#{std_out => [Data | StdOut]}};
handle_info({Port, closed}, #{port := Port} = State) ->
    {stop, ct_port_closed, State};
handle_info({'EXIT', Port, Reason}, #{port := Port} = State) ->
    {stop, {ct_port_exit, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

handle_call(_Request, _From, State) -> {reply, ok, State}.

handle_cast(_Request, State) -> {noreply, State}.

terminate(_Reason, #{port := Port}) ->
    test_exec:kill_process(Port);
terminate(_Reason, _State) ->
    ok.

-doc """
Executes the test in a new node by launching ct_run.
""".
-spec run_test(#test_env{}, integer()) -> port().
run_test(
    #test_env{
        test_spec_file = TestSpecFile,
        output_dir = OutputDir,
        config_files = ConfigFiles,
        dependencies = Dependencies,
        suite_path = SuitePath,
        providers = Providers,
        suite = Suite,
        erl_cmd = ErlCmd,
        extra_flags = ExtraFlags,
        common_app_env = CommonAppEnv0,
        raw_target = RawTarget
    } = _TestEnv,
    PortEpmd
) ->
    % We create the arguments for the ct_run, adding the ebin folder
    % where the suite is as part of the dependencies.
    SuiteFolder = filename:dirname(filename:absname(SuitePath)),
    CodePath = [SuiteFolder | Dependencies],
    CommonAppEnv1 = CommonAppEnv0#{"raw_target" => lists:flatten(io_lib:format("~0p", [RawTarget]))},

    Args = build_run_args(OutputDir, Providers, Suite, TestSpecFile, CommonAppEnv1),

    {ok, ProjectRoot} = file:get_cwd(),

    start_test_node(
        ErlCmd,
        ExtraFlags,
        CodePath,
        ConfigFiles,
        OutputDir,
        [
            {args, Args},
            {env, [
                {"ERL_EPMD_PORT", integer_to_list(PortEpmd)},
                {"PROJECT_ROOT", ProjectRoot}
            ]}
        ]
    ).

-spec build_common_args(
    CodePath :: [file:filename_all()],
    ConfigFiles :: [file:filename_all()]
) -> [string()].
build_common_args(CodePath, ConfigFiles) ->
    lists:append([
        ["-noinput"],
        ["-pa"],
        CodePath,
        config_arg(ConfigFiles)
    ]).

-spec build_run_args(
    OutputDir :: file:filename_all(),
    Providers :: [{module(), [term()]}],
    Suite :: module(),
    TestSpecFile :: file:filename_all(),
    CommonAppEnv :: #{string() => string()}
) -> [string()].
build_run_args(OutputDir, Providers, Suite, TestSpecFile, CommonAppEnv) ->
    lists:append(
        [
            ["-run", "ct_executor", "run"],
            generate_arg_tuple(output_dir, OutputDir),
            generate_arg_tuple(providers, Providers),
            generate_arg_tuple(suite, Suite),
            ["ct_args"],
            generate_arg_tuple(spec, TestSpecFile),
            common_app_env_args(CommonAppEnv)
        ]
    ).

-spec common_app_env_args(Env :: #{string() => string()}) -> [string()].
common_app_env_args(Env) ->
    lists:append([["-common", Key, Value] || Key := Value <- Env]).

-spec start_test_node(
    Erl :: [binary()],
    ExtraFlags :: [string()],
    CodePath :: [file:filename_all()],
    ConfigFiles :: [file:filename_all()],
    OutputDir :: file:filename_all(),
    PortSettings :: port_settings()
) -> port().
start_test_node(
    ErlCmd,
    ExtraFlags,
    CodePath,
    ConfigFiles,
    OutputDir,
    PortSettings0
) ->
    start_test_node(
        ErlCmd,
        ExtraFlags,
        CodePath,
        ConfigFiles,
        OutputDir,
        PortSettings0,
        false
    ).

-spec start_test_node(
    Erl :: [binary()],
    ExtraFlags :: [string()],
    CodePath :: [file:filename_all()],
    ConfigFiles :: [file:filename_all()],
    OutputDir :: file:filename_all(),
    PortSettings :: port_settings(),
    ReplayIo :: boolean()
) -> port().
start_test_node(
    ErlCmd,
    ExtraFlags,
    CodePath,
    ConfigFiles,
    OutputDir,
    PortSettings0,
    ReplayIo
) ->
    % split of args from Erl which can contain emulator flags
    [ErlExecutable | Flags] = ErlCmd,

    % HomeDir is the execution directory.
    HomeDir = set_home_dir(OutputDir),

    %% merge args, enc, cd settings
    LaunchArgs =
        Flags ++ ExtraFlags ++
            build_common_args(CodePath, ConfigFiles) ++
            proplists:get_value(args, PortSettings0, []),

    Env = proplists:get_value(env, PortSettings0, []),
    LaunchEnv = [{"HOME", HomeDir} | Env],

    LaunchCD = proplists:get_value(cd, PortSettings0, HomeDir),

    %% prepare launch settings
    PortSettings1 = lists:foldl(
        fun(Key, Settings) ->
            lists:keydelete(Key, 1, Settings)
        end,
        PortSettings0,
        [args, env, cd]
    ),

    DefaultOptions =
        case ReplayIo of
            true -> [stderr_to_stdout, exit_status, {line, 1024}];
            false -> ?DEFAULT_LAUNCH_PORT_OPTIONS
        end,
    ?LOG_DEBUG("default options ~p", [DefaultOptions]),
    LaunchSettings = [
        {args, LaunchArgs},
        {env, LaunchEnv},
        {cd, LaunchCD}
        | PortSettings1 ++ DefaultOptions
    ],

    %% start the node
    ?LOG_DEBUG(
        io_lib:format("Launching ~tp ~tp ~n with env variables ~tp ~n", [
            ErlExecutable,
            LaunchArgs,
            LaunchEnv
        ])
    ),

    erlang:open_port({spawn_executable, ErlExecutable}, LaunchSettings).

-spec generate_arg_tuple(atom(), [] | term()) -> [io_lib:chars()].
generate_arg_tuple(_Prop, []) ->
    [];
generate_arg_tuple(Prop, ConfigFiles) ->
    [lists:flatten(io_lib:format("~p", [{Prop, ConfigFiles}]))].

config_arg([]) -> [];
config_arg(ConfigFiles) -> ["-config"] ++ ConfigFiles.

-doc """
Create a set up a home dir in the output directory.
Each test execution will have a separate home dir with a
erlang default cookie file, setting the default cookie to
buck2-test-runner-cookie
""".
-spec set_home_dir(file:filename_all()) -> file:filename_all().
set_home_dir(OutputDir) ->
    HomeDir = filename:join(OutputDir, "HOME"),
    ErlangCookieFile = filename:join(HomeDir, ".erlang.cookie"),
    ok = filelib:ensure_dir(ErlangCookieFile),
    ok = file:write_file(ErlangCookieFile, atom_to_list(cookie()), [raw]),
    ok = file:change_mode(ErlangCookieFile, 8#00400),

    % In case the system is using dotslash, we leave a symlink to
    % the real dotslash cache, otherwise erl could be re-downloaded, etc
    try_setup_dotslash_cache(HomeDir),

    HomeDir.

-spec try_setup_dotslash_cache(FakeHomeDir :: file:filename_all()) -> ok.
try_setup_dotslash_cache(FakeHomeDir) ->
    case init:get_argument(home) of
        {ok, [[RealHomeDir]]} ->
            RealDotslashCacheDir = filename:basedir(user_cache, "dotslash"),

            case filelib:is_file(RealDotslashCacheDir, ?raw_file_access) of
                false ->
                    ok;
                true ->
                    RealHomeDirParts = filename:split(RealHomeDir),
                    RealDotslashCacheDirParts = filename:split(RealDotslashCacheDir),

                    case lists:split(length(RealHomeDirParts), RealDotslashCacheDirParts) of
                        {RealHomeDirParts, GenDotslashCacheDirParts} ->
                            FakeHomeDotslashCacheDir = filename:join([FakeHomeDir | GenDotslashCacheDirParts]),
                            ok = filelib:ensure_path(filename:dirname(FakeHomeDotslashCacheDir)),
                            ok = file:make_symlink(RealDotslashCacheDir, FakeHomeDotslashCacheDir),
                            ok;
                        _ ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

-spec cookie() -> atom().
cookie() ->
    'buck2-test-runner-cookie'.

-spec project_root() -> file:filename().
project_root() ->
    {ok, CWD} = file:get_cwd(),
    Command = "buck2 root --kind=project",
    Dir = string:trim(os:cmd(Command)),
    ?LOG_INFO(#{command => Command, result => Dir, cwd => CWD}),
    case filelib:is_dir(Dir, ?raw_file_access) of
        true ->
            Dir;
        false ->
            {ok, FileInfo} = file:read_file_info(Dir),
            ?LOG_ERROR(#{directory => Dir, stat => FileInfo}),
            error({project_root_not_found, Dir})
    end.
