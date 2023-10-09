BITS 64

%define       c_read            0
%define       c_write           1
%define       c_open            2
%define       c_close           3
%define       c_fstat           5
%define       c_mmap            9
%define       c_rt_sigaction    13
%define       c_socket          41
%define       c_bind            49
%define       c_listen          50
%define       c_setsockopt      54
%define       c_exit            60
%define       c_time            201
%define       c_accept4         288

%define       STDOUT            1
%define       PROT_READ         1      
%define       MAP_PRIVATE       2
%define       SIGPIPE           13
%define       AF_INET           2
%define       SOCK_STREAM       1
%define       IPPROTO_TCP       6
%define       TCP_DEFER_ACCEPT  9

%macro int 1
  syscall
%endmacro

%macro sys_write 3
  mov rax, c_write
  mov rdi, %1
  mov rsi, %2
  mov rdx, %3
  syscall
%endmacro

SECTION .bss
  stat_struc  resb            144
  sigaction   resq            4
  timeout     resb            1
  sockaddr    resq            2

SECTION .text
  global      _start

_start:
  cmp         BYTE [rsp],     1                 ; check if argc > 1
  jle         _usage
  lea         rdi,            [rsp+8]           ; skip path
  push        0

_load_file:
  add         rdi,            8                 ; load argv[1]
  mov         rsi,            [rdi]
  test        rsi,            rsi
  jz          _server
  call        _map_file
 
  push        rax                               ; mmap location
  push        rdx                               ; st_size
  push        QWORD [rdi]                       ; fname
  jmp         _load_file

_map_file:
  ; open ()
  mov         r15,            rdi               ; save stack ptr
  mov         rax,            c_open
  mov         rdi,            rsi               ; fname
  xor         rsi,            rsi
  int         0x80
  test        rax,            rax
  js          _err_open
  ; fstat ()
  mov         rdi,            rax               ; fd
  mov         rax,            c_fstat
  lea         rsi,            [stat_struc]      ; struc address
  int         0x80
  test        rax,            rax
  js          _err_fstat
  ; mmap ()
  mov         r8,             rdi               ; fd
  mov         rsi,            [stat_struc+48]   ; st_size
  mov         rax,            c_mmap
  xor         rdi,            rdi               ; no map hint 
  mov         rdx,            PROT_READ
  mov         r10,            MAP_PRIVATE
  xor         r9,             r9                ; no offset
  int         0x80
  test        rax,            rax
  js          _err_mmap
  ; close ()
  mov         rdx,            rax               ; mmap location
  mov         rax,            c_close
  mov         rdi,            r8                ; fd
  int         0x80
  test        rax,            rax
  js          _err_close
  ; prepare for push
  mov         rdi,            r15               ; rdi <- stack ptr
  mov         rax,            rdx               ; rax <- mmap ptr
  mov         rdx,            rsi               ; rdx <- st_size
  ret

_server:
  ; sigaction struc
  push        QWORD 0                           ; sa_mask
  push        QWORD 0                           ; sa_restorer
  push        QWORD 0                           ; sa_flags
  push        QWORD 1                           ; sa_handler [SIG_IGN]
  mov         [sigaction],    rsp
  add         rsp,            0x20              ; fix up the stack
  ; ignore SIGPIPE
  mov         rax,            c_rt_sigaction
  mov         rdi,            SIGPIPE           ; 13
  mov         rsi,            [sigaction]
  xor         rdx,            rdx
  mov         r10,            8
  int         0x80
  ; socket ()
  mov         rax,            c_socket
  mov         rdi,            AF_INET           ; 2
  mov         rsi,            SOCK_STREAM       ; 1
  xor         rdx,            rdx
  int         0x80
  ; TCP_DEFER_ACCEPT
  push        BYTE            10
  mov         [timeout],      rsp               ; set defer_accept_timeout
  add         rsp,            8                 ; fix up the stack
  mov         rdi,            rax
  mov         rax,            c_setsockopt
  mov         rsi,            IPPROTO_TCP       ; 6
  mov         rdx,            TCP_DEFER_ACCEPT  ; 9
  mov         r10,            [timeout]
  mov         r8,             4
  int         0x80
  ; SO_REUSEADDR
  mov         rax,            c_setsockopt
  mov         rsi,            1
  mov         rdx,            2
  mov         r10,            SOCK_ON
  mov         r8,             DWORD 32
  int         0x80
  ; bind ()
  push        DWORD 0                           ; populate sockaddr struc
  push        DWORD 0x0100007F
  push        WORD  0x411F
  push        WORD  2
  mov         [sockaddr],     rsp               ; store sockaddr
  add         rsp,            0x14
  mov         rsi,            [sockaddr]
  mov         rax,            c_bind
  mov         rdx,            DWORD 16          ; addr_len
  int         0x80 
  ; listen ()
  mov         rax,            c_listen
  mov         rsi,            32                ; queue len
  int         0x80

_process_conn: 
  ; accept4 ()
  mov         rax,            c_accept4
  xor         rsi,            rsi
  xor         rdx,            rdx
  mov         r10,            2048              ; SO_NONBLOCK
  int         0x80
  ; read ()
  sub         rsp,            0x400             ; stack buffer
  mov         r14,            rdi               ; store sockfd
  mov         rdi,            rax
  mov         rax,            c_read
  mov         rsi,            rsp               ; 1024 byte buffer
  mov         rdx,            0x400
  int         0x80
  lea         rbp,            [rsp+1000]
  mov         r12,            rdi

  ; check request method
  mov         rsi,            rsp
  xor         rcx,            rcx
  ; "HEAD "
  mov         rdi,            str_head
  call        _strcmp
  cmp         rax,            0
  je          _req
  ; "GET "
  mov         rdi,            str_get
  call        _strcmp
  cmp         rax,            0
  je          _req
  ; "POST "
  mov         rdi,            str_post
  call        _strcmp
  cmp         rax,            0
  je          _req

_strcmp:
  mov         al,             [rdi+rcx]
  mov         ah,             [rsi+rcx]
  cmp         al,             ' '
  jne         _strcnt
  cmp         ah,             ' '
  je          _strscc
_strcnt:
  cmp         al,             ah
  jne          _strfail
  inc         rcx
  jmp         _strcmp
_strscc:
  xor         rcx,            rcx
  mov         rax,            0
  ret
_strfail:
  xor         rcx,            rcx
  mov         rax,            1
  ret

_req:
  cmp         DWORD [rsp],    0x20544547        ; "GET " > little endian
  jne         _exit

_cmp_request:
  add         rbp,            24                ; first stack ptr
  mov         rdi,            [rbp]             ; fname
  test        rdi,            rdi
  jz          _resp_404
  xor         rcx,            rcx               ; reset counter
l1:
  ; get fname len
  cmp         [rdi],          BYTE 0
  jz          l2
  inc         rcx
  inc         rdi
  jmp         l1
l2:
  mov         r11,            rcx
  lea         rsi,            [rsp+5]           ; "GET " resource
  mov         r10,            rcx
  xor         rcx,            rcx
  mov         rdi,            [rbp]
_loop_file:
  mov         al,             [rsi+rcx]
  cmp         al,             ' '               ; str equal
  je          _resp_200
  cmp         al,             [rdi+rcx]
  jne         _cmp_request
  inc         rcx
  jmp         _loop_file

_resp_200:
  cmp         BYTE [rsp+5],   ' '               ; root req
  je          _resp_fallback
  cmp         rcx,            r10
  jl          _resp_404                         ; str incomplete
  mov         rbx,            rcx

  sys_write r12, http_200, len_http_200
  sys_write r12, con_close, len_con_close
  sys_write r12, date, len_date
  sys_write r12, srv_name, len_srv_name
  sys_write r12, content, len_content
  ;mov         rax,            c_write
  ;mov         rdi,            r12               ; client fd
  ;mov         rsi,            str_200_header
  ;mov         rdx,            len_200_header
  ;int         0x80
  mov         rdi,            r12
  mov         rax,            c_write
  mov         rsi,            [rbp+16]          ; mmap ptr
  mov         rdx,            [rbp+8]           ; st_size
  int         0x80
  jmp         _close_conn

_usage:
  mov         rax,            c_write
  mov         rdi,            STDOUT
  mov         rsi,            usage
  mov         rdx,            len_usage
  int         0x80
  jmp         _exit

; err labels
_err_open:
_err_fstat:
_err_mmap:
_err_close:


_resp_404:
  mov         rax,            c_write
  mov         rdi,            r12
  mov         rsi,            str_404_header
  mov         rdx,            len_404_header
  int         0x80
  mov         rax,            c_write
  mov         rsi,            str_404_html
  mov         rdx,            len_404_html
  int         0x80
  jmp         _close_conn

_resp_fallback:
  ; open ()
  mov         rax,            c_open
  mov         rdi,            std_fname
  xor         rsi,            rsi
  int         0x80
  mov         r13,            rax
  ; fstat ()
  mov         rdi,            rax
  mov         rax,            c_fstat
  lea         rsi,            [stat_struc]
  int         0x80
  ; mmap ()
  mov         r8,             rdi
  mov         rsi,            [stat_struc+48]
  mov         rax,            c_mmap 
  xor         rdi,            rdi 
  mov         rdx,            PROT_READ
  mov         r10,            MAP_PRIVATE
  xor         r9,             r9
  int         0x80
  mov         r15,            rax
  ; send header
  mov         rax,            c_write
  mov         rdi,            r12
  mov         rsi,            str_200_header
  mov         rdx,            len_200_header
  int         0x80
  ; send file data
  mov         rax,            c_write
  mov         rsi,            r15
  mov         rdx,            [stat_struc+48]
  int         0x80
  ; close ()
  mov         rax,            c_close
  mov         rdi,            r13
  int         0x80
  ; exit
  mov         rbx,            0
  jmp         _close_conn
            
_close_conn:
  ;mov         rax,            c_time
  ;xor         rdi,            rdi
  ;int         0x80
  ;mov         r11,            rax
  mov         rdi,            STDOUT
  mov         rax,            c_write
  mov         rsi,            str_srv
  mov         rdx,            len_srv
  int         0x80
  ;mov         rax,            c_write
  ;mov         rsi,            r11
  ;mov         rdx,            10
  ;int         0x80
  mov         rax,            c_write
  mov         rsi,            rsp
  mov         rdx,            5
  add         rdx,            rbx
  int         0x80
  mov         rax,            c_write
  mov         rsi,            str_newl
  mov         rdx,            len_newl
  int         0x80  

  mov         rax,            c_close
  mov         rdi,            r12               ; client fd
  int         0x80
  mov         rdi,            r14               ; fallback fd
  add         rsp,            0x400
  jmp         _process_conn

_exit:
  mov         rax,            c_exit
  xor         rdi,            rdi
  int         0x80

SECTION .data
  usage:
    db "usage: ./run <file1> <file2> <...>", 0ah, 0h
  len_usage equ $ - usage

  str_404_header:
    db "HTTP/1.1 404 Not Found", 0ah
    db "Connection: close", 0ah
    db "Date: xxx, xx xxx xxxx xx:xx:xx xxx", 0ah
    db "Server: HTTP-ASM64", 0ah
    db "Content-Type: text/html", 0ah, 0ah, 0h
  len_404_header equ $ - str_404_header

  str_404_html:
    db "<h1>404 Not Found</h1>", 0ah
  len_404_html equ $ - str_404_html

  str_200_header:
    db "HTTP/1.1 200 OK", 0ah
    db "Connection: close", 0ah
    db "Date: xxx, xx xxx xxxx xx:xx:xx xxx", 0ah
    db "Server: HTTP-ASM64", 0ah
    db "Content-Type: text/html", 0ah, 0ah, 0h
  len_200_header equ $ - str_200_header

  http_200 db "HTTP/1.1 200 OK", 0ah
  len_http_200 equ $ - http_200
  http_404 db "HTTP/1.1 404 Not Found", 0ah
  len_http_404 equ $ - http_404
  con_close db "Connection: close", 0ah
  len_con_close equ $ - con_close
  date db "Date: xxx, xx xxx xxxxx xx:xx:xx xxx", 0ah
  len_date equ $- date
  srv_name db "Server: HTTP-ASM64", 0ah
  len_srv_name equ $ - srv_name
  content db "Content-Type: text/html", 0ah, 0ah, 0h
  len_content equ $ - content


  std_fname db "index.html", 0h

  str_srv db "[http-asm] ", 0h
  len_srv equ $ - str_srv

  str_newl db "", 0ah, 0h
  len_newl equ $ - str_newl

  str_head db "HEAD ", 0h
  len_head equ $ - str_head

  str_get db "GET ", 0h
  len_get equ $ - str_get

  str_post db "POST ", 0h
  len_post equ $ - str_post

  SOCK_ON     dw              1
