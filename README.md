# ed
#### A VIM based text editor, from scratch, no 3rd party libraries, optimized for my text editing preferences
Proudly contains no AI-generated code.
<img width="1005" height="992" alt="image" src="https://github.com/user-attachments/assets/7105beed-ac04-4945-81e2-665d73e21a99" />




https://github.com/user-attachments/assets/eebd6a45-de3c-406b-b9da-0f773a6f7b18




### Noteable
* Uses a paged, rope data structure for efficiently manipulating large text files. Rope is pretty standard, but I'm using paged to mean splitting up the text file into fixed sized chunks (a page), and only loading those pages into memory (each page is its own rope).
* Uses a token based syntax highlighter. Most editors I've seen either use some kind of regex on the character level, or full on parsing. But I found that tokenizing the code is simpler, and produces quite comfortable highlighting.
* Uses DirectX 11 for rendering. People seem to be obsessed with TUI applications. I'd rather have a GUI application as it's more flexible, more performant, and easier to build.

### Future
* Integrated terminal emulator. Or have something like Emacs compilation mode. I like the ability in VSCode to be able to ctrl+click on compilation errors in the terminal and the editor relocates to the error location.
* Networked code collaboration. We've tried using VSCode live share, but it's extremely buggy (gets out of sync very easily), and we would rather be able to sync codebases on each participant's computer, rather than having it only on the host's computer.
