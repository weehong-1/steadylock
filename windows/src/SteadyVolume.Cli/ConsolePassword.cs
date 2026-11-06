using System.Text;

namespace SteadyVolume.Cli;

/// <summary>Reads a password without echoing it. Passwords are never taken from the command line.</summary>
internal static class ConsolePassword
{
    public static string Read(string prompt)
    {
        Console.Write(prompt);

        if (Console.IsInputRedirected)
        {
            // Non-interactive use (stdin is a pipe or file). Nothing is echoed in this case anyway.
            // Windows PowerShell can put a UTF-8 byte-order mark in front of the first piped line, and
            // files saved on Windows end lines with \r\n; neither is part of the password.
            var line = (Console.In.ReadLine() ?? string.Empty).TrimStart('﻿').TrimEnd('\r');
            Console.WriteLine();
            return line;
        }

        var buffer = new StringBuilder();
        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            switch (key.Key)
            {
                case ConsoleKey.Enter:
                    Console.WriteLine();
                    return buffer.ToString();
                case ConsoleKey.Backspace:
                    if (buffer.Length > 0)
                        buffer.Length--;
                    break;
                case ConsoleKey.Escape:
                    buffer.Clear();
                    break;
                default:
                    if (!char.IsControl(key.KeyChar))
                        buffer.Append(key.KeyChar);
                    break;
            }
        }
    }
}
