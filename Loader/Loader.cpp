// Loader.cpp : Этот файл содержит функцию "main". Здесь начинается и заканчивается выполнение программы.
//

#include <iostream>
#include <filesystem>
#include <array>
#include <array>
#include <conio.h>

#include <Windows.h>
#include <Psapi.h>
#include <tlhelp32.h>
#include <winternl.h>



constexpr std::string_view modloader_file = "ModLoader.dll";

static void log_from_pipe(HANDLE pipe) {
    std::array<char, 512> buffer = { 0 };
    DWORD bytes_read = 0;
    while (true) {
        if (!ReadFile(pipe, buffer.data(), buffer.size(), &bytes_read, nullptr)) {
            DWORD error = GetLastError();
            if (error == ERROR_BROKEN_PIPE) {
                std::cerr << "\nPipe disconnected or closed\n";
            }
            else {
                std::cerr << "\nFailed to read log\n";
            }
            return;
        }
        std::cout << std::string_view(buffer.data(), bytes_read);
    }
}

bool need_exit_interrupt = true;

void press_any_key() {
    if (need_exit_interrupt) {
        std::cerr << "Press any key... ";
        static_cast<void>(_getch());
    }
}

int main(int argc, char** argv) {
    std::atexit(press_any_key);

    constexpr std::string_view named_pipe_name = R"(\\.\pipe\WindowHookDebugLog)";
    std::filesystem::path game_exe = "Game.exe";
    std::filesystem::path dll_path = modloader_file;
    STARTUPINFOA si = { 0 };
    si.cb = sizeof(si);

    if (!std::filesystem::exists(dll_path)) {
        std::cerr << "Failed to find ModLoader file\n";
        return -1;
    }

    if (!std::filesystem::exists(game_exe)) {
        std::cerr << "Failed to find Game file\n";
        return -1;
    }

    PROCESS_INFORMATION pi;
    std::string root_path = game_exe.parent_path().string();
    if (!CreateProcessA(game_exe.string().c_str(), game_exe.string().data(), nullptr, nullptr, FALSE, CREATE_SUSPENDED, nullptr, !root_path.empty() ? root_path.c_str() : nullptr , &si, &pi)) {
        std::cerr << "Failed to create process\n";
        return -1;
    }

    HMODULE kernel32 = GetModuleHandle(TEXT("kernel32.dll"));
    void* load_library_proc = GetProcAddress(kernel32, "LoadLibraryA");

    SIZE_T alloc_size = dll_path.string().size();
    LPVOID allocated_mem = VirtualAllocEx(pi.hProcess, nullptr, alloc_size, MEM_COMMIT, PAGE_READWRITE);
    if (!allocated_mem) {
        TerminateProcess(pi.hProcess, -1);
        std::cerr << "Failed to allocate memory";
        return -1;
    }

    if (!WriteProcessMemory(pi.hProcess, allocated_mem, dll_path.string().c_str(), alloc_size, nullptr)) {
        TerminateProcess(pi.hProcess, -1);
        std::cerr << "Failed to write memory";
        return -1;
    }

    HANDLE pipe_handle = CreateNamedPipeA(named_pipe_name.data(), PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 0, 0, NMPWAIT_USE_DEFAULT_WAIT, nullptr);
    if (pipe_handle == INVALID_HANDLE_VALUE) {
        TerminateProcess(pi.hProcess, -1);
        std::cerr << "Failed to create pipe\n";
        return -1;
    }
    
    DWORD thread_id;
    HANDLE dll_thread_handle = CreateRemoteThread(pi.hProcess, nullptr, 0, (LPTHREAD_START_ROUTINE)load_library_proc, allocated_mem, 0, &thread_id);
    if (dll_thread_handle == INVALID_HANDLE_VALUE) {
        TerminateProcess(pi.hProcess, -1);
        std::cout << "Failed to create thread\n";
        return -1;
    }

    if (!ConnectNamedPipe(pipe_handle, nullptr)) {
        TerminateProcess(pi.hProcess, -1);
        std::cout << "Failed to wait pipe\n";
        return -1;
    }

    ResumeThread(pi.hThread);
    CloseHandle(pi.hProcess);

    std::cout << "Game started\n";

    log_from_pipe(pipe_handle);

    CloseHandle(pipe_handle);

    need_exit_interrupt = false;

    return 0;
}

// Запуск программы: CTRL+F5 или меню "Отладка" > "Запуск без отладки"
// Отладка программы: F5 или меню "Отладка" > "Запустить отладку"

// Советы по началу работы 
//   1. В окне обозревателя решений можно добавлять файлы и управлять ими.
//   2. В окне Team Explorer можно подключиться к системе управления версиями.
//   3. В окне "Выходные данные" можно просматривать выходные данные сборки и другие сообщения.
//   4. В окне "Список ошибок" можно просматривать ошибки.
//   5. Последовательно выберите пункты меню "Проект" > "Добавить новый элемент", чтобы создать файлы кода, или "Проект" > "Добавить существующий элемент", чтобы добавить в проект существующие файлы кода.
//   6. Чтобы снова открыть этот проект позже, выберите пункты меню "Файл" > "Открыть" > "Проект" и выберите SLN-файл.
