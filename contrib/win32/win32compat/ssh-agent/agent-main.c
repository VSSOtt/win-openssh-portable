/*
 * Author: Manoj Ampalam <manoj.ampalam@microsoft.com>
 * ssh-agent implementation on Windows
 * NT Service routines
 *
 * Copyright (c) 2015 Microsoft Corp.
 * All rights reserved
 *
 * Microsoft openssh win32 port
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "agent.h"
#include "..\misc_internal.h"
#include "..\Debug.h"
#include <wchar.h>
#include <sddl.h>

#pragma warning(push, 3)

/* Pattern-list of allowed PKCS#11/Security key paths */
char* allowed_providers = NULL;

int remote_add_provider;

/*
 * -v/-vv/-vvv/-vvvv: log level VERBOSE/DEBUG1/DEBUG2/DEBUG3 (0 = default,
 * INFO) written to %ProgramData%\ssh\logs\ssh-agent.log (LOCAL0 facility).
 * Passed on to the per-connection worker processes.
 */
int agent_verbosity;

/* -D: with -d/-dd/-ddd keep serving connections instead of exiting after one */
int agent_keep_running;

int scm_start_service(DWORD, LPWSTR*);

/*
 * Make sure %ProgramData%\ssh\logs exists. Directories that are created here
 * are only accessible to SYSTEM and Administrators, like the logs of sshd.
 * Returns 1 if the directory exists afterwards.
 */
static int
ensure_logs_dir(void)
{
	wchar_t ssh_dir[PATH_MAX] = { 0 }, logs_dir[PATH_MAX] = { 0 };
	SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), NULL, FALSE };
	int ok = 0;

	if (swprintf_s(ssh_dir, PATH_MAX, L"%s\\ssh", __wprogdata) <= 0 ||
	    swprintf_s(logs_dir, PATH_MAX, L"%s\\logs", ssh_dir) <= 0)
		return 0;
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
	    L"D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
	    &sa.lpSecurityDescriptor, NULL))
		return 0;
	if ((CreateDirectoryW(ssh_dir, &sa) || GetLastError() == ERROR_ALREADY_EXISTS) &&
	    (CreateDirectoryW(logs_dir, &sa) || GetLastError() == ERROR_ALREADY_EXISTS))
		ok = 1;
	LocalFree(sa.lpSecurityDescriptor);
	return ok;
}

/*
 * Initialize logging for the service and its workers. Without -v this is the
 * event log at INFO level. With -v the log level is raised and output goes to
 * %ProgramData%\ssh\logs\ssh-agent.log (the directory is created if needed);
 * if that is not possible the event log is used.
 */
static void
agent_log_init(void)
{
	SyslogFacility facility = SYSLOG_FACILITY_USER;
	LogLevel level = SYSLOG_LEVEL_INFO;
	int logs_dir_missing = 0;

	if (agent_verbosity > 0) {
		level = (LogLevel)(SYSLOG_LEVEL_INFO + agent_verbosity);
		if (ensure_logs_dir())
			facility = SYSLOG_FACILITY_LOCAL0;
		else
			logs_dir_missing = 1;
	}
	log_init("ssh-agent", level, facility, 0);
	if (logs_dir_missing)
		error("cannot create directory %%ProgramData%%\\ssh\\logs, "
		    "logging to the event log instead of ssh-agent.log");
}

SERVICE_TABLE_ENTRYW dispatch_table[] =
{
	{ L"ssh-agent", (LPSERVICE_MAIN_FUNCTIONW)scm_start_service },
	{ NULL, NULL }
};
static SERVICE_STATUS_HANDLE service_status_handle;
static SERVICE_STATUS service_status;


static VOID 
ReportSvcStatus(DWORD dwCurrentState, DWORD dwWin32ExitCode, DWORD dwWaitHint)
{
	service_status.dwCurrentState = dwCurrentState;
	service_status.dwWin32ExitCode = dwWin32ExitCode;
	service_status.dwWaitHint = dwWaitHint;

	if (dwCurrentState == SERVICE_START_PENDING)
		service_status.dwControlsAccepted = 0;
	else
		service_status.dwControlsAccepted = SERVICE_ACCEPT_STOP;

	if ((dwCurrentState == SERVICE_RUNNING) || (dwCurrentState == SERVICE_STOPPED))
		service_status.dwCheckPoint = 0;
	else
		service_status.dwCheckPoint = 1;

	SetServiceStatus(service_status_handle, &service_status);
}

static VOID WINAPI 
service_handler(DWORD dwControl)
{
	switch (dwControl)
	{
	case SERVICE_CONTROL_STOP: {
		ReportSvcStatus(SERVICE_STOP_PENDING, NO_ERROR, 500);
		agent_shutdown();
		ReportSvcStatus(SERVICE_STOPPED, NO_ERROR, 0);
		return;
	}
	case SERVICE_CONTROL_INTERROGATE:
		break;
	default:
		break;
	}

	ReportSvcStatus(service_status.dwCurrentState, NO_ERROR, 0);
}

BOOL WINAPI 
ctrl_c_handler(_In_ DWORD dwCtrlType) 
{
	/* for any Ctrl type, shutdown agent*/
	debug4("Ctrl+C received");
	agent_shutdown();
	return TRUE;
}

/*set current working directory to module path*/
static void
fix_cwd()
{
	wchar_t path[PATH_MAX] = { 0 };
	int i, lastSlashPos = 0;
	GetModuleFileNameW(NULL, path, PATH_MAX);
	for (i = 0; path[i]; i++) {
		if (path[i] == L'/' || path[i] == L'\\')
			lastSlashPos = i;
	}

	path[lastSlashPos] = 0;
	_wchdir(path);
}

extern void sanitise_stdfd(void);

int 
wmain(int argc, wchar_t **wargv)
{
	_set_invalid_parameter_handler(invalid_parameter_handler);
	w32posix_initialize();
	fix_cwd();
	/* Check if -Oallow-remote-pkcs11 has been passed in for all scenarios */
	if (argc >= 2) {
		for (int i = 0; i < argc; i++) {
			if (wcsncmp(wargv[i], L"-O", 2) == 0) {
				if (wcsncmp(wargv[i], L"-Oallow-remote-pkcs11", 21) == 0) {
					remote_add_provider = 1;
				}
				else {
					fatal("Unknown -O option; only allow-remote-pkcs11 is supported");
				}
			}
			else if (wcsncmp(wargv[i], L"-P", 2) == 0) {
				if (allowed_providers != NULL)
					fatal("-P option already specified");
				if ((i + 1) < argc) {
					i++;
					if ((allowed_providers = utf16_to_utf8(wargv[i])) == NULL)
						fatal("Invalid argument for -P option");
				}
				else {
					fatal("Missing argument for -P option");
				}
			}
			else if (wcsncmp(wargv[i], L"-v", 2) == 0) {
				int n = 0;
				const wchar_t *p = wargv[i] + 1;

				while (*p == L'v') {
					n++;
					p++;
				}
				if (*p != L'\0')
					fatal("Invalid option %ls", wargv[i]);
				agent_verbosity = n > 4 ? 4 : n;
			}
			else if (wcscmp(wargv[i], L"-D") == 0) {
				agent_keep_running = 1;
			}
		}
	}

	if (allowed_providers == NULL) {
		agent_initialize_allow_list();
	}

	if (!StartServiceCtrlDispatcherW(dispatch_table)) {
		if (GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
			/* Ensure that fds 0, 1 and 2 are open or directed to /dev/null */
			sanitise_stdfd();

			/*
			 * agent is not spawned by SCM
			 * Its either started in debug mode or a worker child
			 * If running in debug mode, args are (any order): -d, -dd, or -ddd and -Oallow-remote-pkcs11 (optional)
			 * If a worker child, args are (in this order): int (connection handle) and -Oallow-remote-pkcs11 (optional) 
			 */

			if (argc >= 2) {
				for (int i = 0; i < argc; i++) {
					if (wcsncmp(wargv[i], L"-ddd", 4) == 0) {
						log_init("ssh-agent", 7, 1, 1);
					}
					else if (wcsncmp(wargv[i], L"-dd", 3) == 0) {
						log_init("ssh-agent", 6, 1, 1);
					}
					else if (wcsncmp(wargv[i], L"-d", 2) == 0) {
						log_init("ssh-agent", 5, 1, 1);
					}

					/* Set Ctrl+C handler if starting in debug mode */
					if (wcsncmp(wargv[i], L"-d", 2) == 0) {
						SetConsoleCtrlHandler(ctrl_c_handler, TRUE);
						agent_start(TRUE);
						return 0;
					}

					/*agent process is likely a spawned child*/
					char* h = 0;
					h += _wtoi(*(wargv + i));
					if (h != 0) {
						agent_log_init();
						agent_process_connection(h);
						return 0;
					}
				}
			}
			/* to support linux compat scenarios where ssh-agent.exe is typically launched per session*/
			/* - just start ssh-agent service if needed */
			{
				SC_HANDLE sc_handle, svc_handle;

				if ((sc_handle = OpenSCManagerW(NULL, NULL, SERVICE_START)) == NULL ||
					(svc_handle = OpenServiceW(sc_handle, L"ssh-agent", SERVICE_START)) == NULL) {
					fatal("unable to open service handle");
					return -1;
				}

				if (StartService(svc_handle, 0, NULL) == FALSE && GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) {
					fatal("unable to start ssh-agent service, error :%d", GetLastError());
					return -1;
				}

				return 0;
			}
		}
		else
			return -1;
	}
	return 0;
}

int 
scm_start_service(DWORD num, LPWSTR* args) 
{
	service_status_handle = RegisterServiceCtrlHandlerW(L"ssh-agent", service_handler);
	ZeroMemory(&service_status, sizeof(service_status));
	service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
	ReportSvcStatus(SERVICE_START_PENDING, NO_ERROR, 300);
	ReportSvcStatus(SERVICE_RUNNING, NO_ERROR, 0);
	agent_log_init();
	logit("ssh-agent service started: log verbosity %d, allowed providers \"%.200s\"",
	    agent_verbosity, allowed_providers ? allowed_providers : "");
	agent_start(FALSE);
	return 0;
}

#pragma warning(pop)
