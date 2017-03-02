unit epollsockets;
{
 an abstraction layer for handling sockets with epoll

 Copyright (C) 2016 Simon Ley

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published
 by the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
}

{$i besenws.inc}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  baseunix,
  unix,
  linux,
  sockets,
  synsock,
{$IFDEF OPENSSL_SUPPORT}
  ssl_openssl_lib,
{$ENDIF}
  logging;

const
  { maximum concurrent connections per thread }
  MaxConnectionsPerThread = 40000;

type
  TEPollSocket = class;
  TEpollWorkerThread = class;
  TEPollSocketEvent = procedure(Sender: TEPollSocket) of object;

  TEPollCallbackProc = procedure of object;

  { TEPollSocket }

  TEPollSocket = class
  private
    FOutbuffer: ansistring;
    FOutbuffer2: ansistring;
    FonDisconnect: TEPollSocketEvent;
    FParent: TEpollWorkerThread;
    FSocket: TSocket;
    FRemoteIP, FRemoteIPPort: ansistring;
    FWantClose: Boolean;
{$IFDEF OPENSSL_SUPPORT}
    FWantSSL: Boolean;
    FIsSSL: Boolean;
    FSSLContext: PSSL_CTX;
    FSSL: PSSL;
    FSSLWantWrite: Boolean;
    procedure CheckSSLError(ErrNo: Longword);
{$ENDIF}
    { internal callback function that adds socket in parent thread }
    procedure AddCallback;
  protected
    { process incoming data - called by worker thread, has to be overridden }
    procedure ProcessData(const Data: ansistring); virtual; abstract;
    { send data - if flush is true, data will be immediately written to the
      socket, or stored until FlushSendbuffer is called }
    procedure SendRaw(const Data: ansistring; Flush: Boolean = True);
    { reads up to Length(Data) bytes from socket - called by worker thread.
      'Data' acts as a temporary buffer }
    function ReadData(var Data: ansistring): Boolean;
    { flush data that needs to be written to the socket - can be called manually,
      but is also called from worker thread (e.g. when not all data can be sent
      in one pass) }
    function FlushSendbuffer: Boolean;
    { returns true when the socket can be closed, and all outgoing data has
      been sent }
    function WantClose: Boolean;
    { returns true if socket can be closed. override this to add custom checks,
      is called by thread worker to determine if class can be removed from queue }
    function CheckTimeout: Boolean; virtual;
  public
    constructor Create(Socket: TSocket);
    destructor Destroy; override;
    { performs cleanup - closes socket, disposes any data that is held in class
      members. After cleanup, the class can be reused using .Reassign() }
    procedure Cleanup; virtual;
    { this frees the class. in derived classes this can be overridden to
      e.g. put this class instance back into a pool, instead of freeing }
    procedure Dispose; virtual;
    { assigns a new socket to to reuse the class. Cleanup must have been called
      before }
    procedure Reassign(Socket: TSocket);
    { move socket to another worker thread }
    procedure Relocate(NewParent: TEpollWorkerThread);
    { marks the connection as "WantClosed". Remaining asynchronous send operations
      will be finished first before the socket is actually closed. this is done
      in the worker thread }
    procedure Close;
    { returns ip and port }
    function GetPeerName: string;
    { returns ip }
    function GetRemoteIP: string;
{$IFDEF OPENSSL_SUPPORT}
    { performs ssl handshake }
    procedure StartSSL;
    { cleans up ssl - you probably don't want to call this manually }
    procedure StopSSL;
{$ENDIF}
    { actual socket handle }
    property Socket: TSocket read FSocket;
    { Parent Thread }
    property Parent: TEpollWorkerThread read FParent;
    { callback function when socket is closed }
    property OnDisconnect: TEPollSocketEvent read FonDisconnect write FOnDisconnect;
{$IFDEF OPENSSL_SUPPORT}
    { returns true if ssl has been loaded }
    property IsSSL: Boolean read FIsSSL;
    { if true, SSL handshake is performed }
    property WantSSL: Boolean read FWantSSL write FWantSSL;
    { the associated openssl context }
    property SSLContext: PSSL_CTX read FSSLContext write FSSLContext;
{$ENDIF}
  end;

  { TEpollWorkerThread }

  TEpollWorkerThread = class(TThread)
  private
    FEpollFD: integer;
    FSocketCount: Integer;
    FEpollEvents: array[0..MaxConnectionsPerThread] of epoll_event;
    FSockets: array[0..MaxConnectionsPerThread-1] of TEPollSocket;
    FParent: TObject;
    FTicks: Integer;
    FTotalCount: Integer;
    FPipeInput,
    FPipeOutput: THandle;
    FOnConnection: TEPollSocketEvent;
    procedure RemoveSocket(Sock: TEPollSocket; doClose: Boolean = True; doFree: Boolean = true);
  protected
    { called inbetween epoll, checks for client timeouts }
    procedure ThreadTick; virtual;
    { overriden thread function }
    procedure Execute; override;
    { add socket - this is called from TEPollSocket-relocate within this thread }
    function AddSocket(Sock: TEPollSocket): Boolean;
  public
    constructor Create(aParent: TObject);
    destructor Destroy; override;
    { execute callback proc in thread }
    function Callback(Method: TEPollCallbackProc): Boolean;
    property EPollFD: integer read FEPollFD write FEpollFD;
    property OnConnection: TEPollSocketEvent read FOnConnection write FOnConnection;
    property Totalcount: Integer read FTotalCount;
    property Parent: TObject read FParent;
  end;

implementation

uses
  besenwebsocket,
  webserver;

const
  { Default waiting time for epoll }
  EpollWaitTime = 100;
  { ticks until CheckTimeout function is called }
  ClientTickInterval = 1000 div EpollWaitTime;

{ TEPollSocket }

{$IFDEF OPENSSL_SUPPORT}
procedure TEPollSocket.CheckSSLError(ErrNo: Longword);
var
  i: Integer;
  s: string;
begin
  i:=SslGetError(fssl, ErrNo);
  case i of
    SSL_ERROR_NONE: dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_NONE');
    SSL_ERROR_SSL: begin
      setlength(s, 256);
      ErrErrorString(ErrGetError, s, Length(s));
      dolog(llError, GetPeerName+': SSL Error - '+s);
      FWantclose:=True;
    end;
    SSL_ERROR_SYSCALL:
    begin
      if ErrNo<>0 then
      begin
        setlength(s, 256);
        ErrErrorString(ErrGetError, s, Length(s));
        dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_SYSCALL -'+s);
      end;
      FWantclose:=True;
    end;
    SSL_ERROR_WANT_CONNECT: dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_WANT_CONNECT');
    SSL_ERROR_WANT_READ:
    begin
      // this error can be savely ignored - data will be read automatically via epoll
    end;
    SSL_ERROR_WANT_WRITE:
    begin
      // openssl wants a
      FSSLWantWrite:=True;
      FlushSendbuffer;
    end;
    SSL_ERROR_WANT_X509_LOOKUP: dolog(llError, GetPeerName+': SSL Read Error - SSL_ERROR_WANT_X509_LOOKUP');
    SSL_ERROR_ZERO_RETURN:
    begin
      dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_ZERO_RETURN');
      FWantclose:=True;
    end;

    SSL_ERROR_WANT_ACCEPT: dolog(llError, GetPeerName+': SSL Read Error - SSL_ERROR_WANT_ACCEPT');
    else
      dolog(llError, GetPeerName+': SSL Read Error - Other #'+IntToStr(i));
  end;
end;

procedure TEPollSocket.AddCallback;
begin
  if not FParent.AddSocket(Self) then
  begin
    dolog(llError, GetPeerName + ': Could not relocate to thread, dropping!');
    FParent:=nil;
    FWantclose:=True;
    //FSockets[i+k].OnDisconnect:=nil;
    Dispose;
  end;
end;

{$ENDIF}

procedure TEPollSocket.SendRaw(const Data: ansistring; Flush: Boolean);
begin
{$IFDEF OPENSSL_SUPPORT}
  if FSSLWantWrite then
  begin
    FOutbuffer2:=FOutbuffer2 + data;
    Exit;
  end;
{$ENDIF}

  FOutbuffer:=FOutbuffer + data;
  if Flush then
    FlushSendbuffer;
end;

function TEPollSocket.ReadData(var Data: ansistring): Boolean;
var
  k, err: Integer;
  data2: ansistring;
begin
{$IFDEF OPENSSL_SUPPORT}
  if FIsSSL then
  begin
    k:=SslRead(FSSL, @Data[1], Length(Data));
    if k<=0 then
    begin
      result:=False;
      CheckSSLError(k);
    end else
    begin
      data2:=data;
      Setlength(data2, k);
      ProcessData(data2);
      data2:='';
      result:=True;
    end;
    Exit;
  end;
{$ENDIF}

  k := fprecv(FSocket, @data[1], Length(data), MSG_DONTWAIT or MSG_NOSIGNAL);
  if k<=0 then
  begin
    if k<0 then
    begin
      err:=fpgeterrno;
      case err of
        ESysEWOULDBLOCK: result:=True;
        ESysECONNRESET:
        begin
          dolog(llDebug, GetPeerName+': Connection reset');
          result:=False;
          FWantClose:=True;
        end;
        ESysETIMEDOUT:
        begin
          dolog(llDebug, GetPeerName+': Connection timeout');
          result:=False;
          FWantClose:=True;
        end;
        else
        begin
          dolog(llDebug, GetPeerName+': error in fprecv #'+IntTostr(err));
          result:=False;
          FWantClose:=True;
        end;
      end;
    end else
    begin
      result:=False; // connection closed
      FWantClose:=True;
    end;
  end else
  begin
    data2:=data;
    Setlength(data2, k);
    ProcessData(data2);
    data2:='';
    result:=True;
  end;
end;

function TEPollSocket.FlushSendbuffer: Boolean;
var
  i: Integer;
  event: epoll_event;
begin
  result:=False;

  if not Assigned(FParent) then
    Exit;

  if (Length(FOutbuffer)>0)
{$IFDEF OPENSSL_SUPPORT}
     or(FSSLWantWrite)
{$ENDIF}
  then begin

{$IFDEF OPENSSL_SUPPORT}
    if FIsSSL then
    begin
      // openssl might want to write something even when we have no data
      if Length(FOutBuffer)=0 then
        i:=SslWrite(FSSL, nil, 0)
      else
        i:=SslWrite(FSSL, @FOutBuffer[1], Length(FOutbuffer));

      FSSLWantWrite:=False;
      if i<=0 then
      begin
        CheckSSLError(i);
        i:=0;
      end else
        result:=True;
    end else
{$ENDIF}
    begin
      i:=fpsend(FSocket, @FOutbuffer[1], Length(FOutbuffer), MSG_DONTWAIT or MSG_NOSIGNAL);
      if i<0 then
      begin
        dolog(llError, GetPeerName+': Error in fpsend #'+IntTostr(fpgeterrno));
        FWantclose:=True;
      end
      else if i=0 then
        dolog(llDebug, GetPeerName+': fpsend Could not send anything, #'+IntTostr(fpgeterrno))
      else
        result := True;
    end;

    if result and (i>0) then
      delete(FOutbuffer, 1, i);

    if (Length(FOutBuffer)>0)
{$IFDEF OPENSSL_SUPPORT}
       or FSSLWantWrite
{$ENDIF}
    then begin
      event.Events:=EPOLLIN or EPOLLOUT;
      event.Data.ptr:=Self;
      if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
        dolog(llDebug, GetPeerName+': epoll_ctl_mod failed (epollin+epollout), error #'+IntTostr(fpgeterrno));
    end else
    if (Length(FOutbuffer)=0)and(Length(FOutbuffer2)>0) then
    begin
      FOutbuffer:=FOutbuffer2;
      FOutbuffer2:='';
      FlushSendbuffer();
    end;
  end else
  begin
   event.Events:=EPOLLIN;
   event.Data.ptr:=Self;
   if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
     dolog(llDebug, GetPeerName+': epoll_ctl_mod failed (epollin), error #'+IntTostr(fpgeterrno));
  end;
end;

constructor TEPollSocket.Create(Socket: TSocket);
begin
  FParent:=nil;
  FSocket:=Socket;
end;

function TEPollSocket.GetPeerName: string;
var
  len: integer;
  Name: TVarSin;
begin
  if FRemoteIPPort<>'' then
    result:=FRemoteIPPort
  else begin
    begin
      len := SizeOf(name);
      FillChar(name, len, 0);
      fpGetPeerName(FSocket, @name, @Len);
      FRemoteIP:=GetSinIP(Name);
      FRemoteIPPort:=FRemoteIP+'.'+IntToStr(GetSinPort(Name));
      result:=FRemoteIP;
    end;
  end;
end;

function TEPollSocket.GetRemoteIP: string;
begin
  if FRemoteIP='' then
    GetPeerName;
  result:=FRemoteIP;
end;

procedure TEPollSocket.Relocate(NewParent: TEpollWorkerThread);
begin
  if Assigned(FParent) then
    FParent.RemoveSocket(Self, False, False);

  FParent:=NewParent;
  if not NewParent.Callback(AddCallback) then
  begin
    dolog(llError, GetPeerName+': Callback for relocation failed, dropping!');
    FParent:=nil;
    FWantClose:=True;
    Dispose;
  end;
end;

destructor TEPollSocket.Destroy;
begin
  Cleanup;
  inherited Destroy;
end;

procedure TEPollSocket.Reassign(Socket: TSocket);
begin
  if FSocket<>0 then
    raise Exception.Create('TEpollSocket.Reassign was called while still holding socket');
  FParent:=nil;
  FSocket:=Socket;
end;

{$IFDEF OPENSSL_SUPPORT}
procedure TEPollSocket.StartSSL;
var
  i: Integer;
begin
  if FIsSSL then
    Exit;
  GetPeerName;
  fssl := SslNew(FSSLContext);
  if Assigned(fssl) then
  begin
    i:=SslSetFd(fssl, FSocket);
    if i<=0 then
      CheckSSLError(i);
    i:=SslAccept(fssl);
    if i<=0 then
      CheckSSLError(i);
    FIsSSL:=True;
  end else
    dolog(llError, 'SSL_new() failed!');
end;

procedure TEPollSocket.StopSSL;
begin
   if not FIsSSL then
     Exit;
  SslFree(fssl);
  FIsSSL:=False;
  Fssl:=nil;
end;

{$ENDIF}

procedure TEPollSocket.Cleanup;
begin
   if Assigned(FonDisconnect) then
     FonDisconnect(Self);

 {$IFDEF OPENSSL_SUPPORT}
   if FIsSSL then
     StopSSL;
 {$ENDIF}
   if FSocket<>0 then
     fpclose(FSocket);
   FSocket:=0;
   FWantclose:=False;
   FOutbuffer:='';
   FOutbuffer2:='';
   FRemoteIP:='';
   FRemoteIPPort:='';
   FOnDisconnect:=nil;
end;

procedure TEPollSocket.Dispose;
begin
  Free;
end;

procedure TEPollSocket.Close;
begin
  FWantClose:=True;
end;

function TEPollSocket.WantClose: Boolean;
begin
  result:=(FOutbuffer='')and FWantclose;
end;

function TEPollSocket.CheckTimeout: Boolean;
begin
  result:=FWantClose;
end;

{ TEpollWorkerThread }

procedure TEpollWorkerThread.Execute;
var
  i, j: Integer;
  data: ansistring;
  conn: TEPollSocket;
  Callback: TEPollCallbackProc;
  event: epoll_event;
begin
  epollfd:=0;
  epollfd := epoll_create(MaxConnectionsPerThread);

  // add callback pipe
  event.Events:=EPOLLIN;
  event.Data.fd:=FPipeOutput;
  fpfcntl(FPipeOutput, F_SetFl, fpfcntl(FPipeOutput, F_GetFl) or O_NONBLOCK);
  if epoll_ctl(epollfd, EPOLL_CTL_ADD, FPipeOutput, @event)<0 then
  begin
    dolog(llError, 'epoll_ctl_add pipe failed, error #'+IntTostr(fpgeterrno)+' ');
  end;

  Setlength(data, 64*1024); // temporary buffer

  while (not Terminated) do
  begin
    i := epoll_wait(epollfd, @FEpollEvents[0], FSocketCount+1, EpollWaitTime);
    for j:=0 to i-1 do
    if FEpollEvents[j].Data.fd = FPipeOutput then
    begin
      // we only expect class function pointers from the callback pipe
      if FpRead(FEpollEvents[j].data.fd, Callback, SizeOf(Callback)) = SizeOf(Callback) then
      begin
        Callback();
      end else
        dolog(llError, 'Error reading epollworkerthread callback');
    end else
    if Assigned((FEpollEvents[j].data.ptr)) then
    begin
      conn:=TEPollSocket(FEpollEvents[j].data.ptr);

      if conn.FParent <> Self then
      begin
        dolog(llError, conn.GetPeerName+': got epoll message from connection located in different thread');
      end else
      if (FEpollEvents[j].Events and EPOLLIN<>0) then
      begin
        conn.ReadData(Data);
      end else if (FEpollEvents[j].Events and EPOLLOUT<>0) then
      begin
        conn.FlushSendbuffer;
      end else if (FEpollEvents[j].Events and EPOLLERR<>0) then
      begin
        dolog(llDebug, 'got epoll-error '+Inttostr(fpgeterrno));
        conn.FWantclose:=True;
      end else
      begin
        dolog(llDebug, 'unknown epoll-event '+IntToStr(FEpollEvents[j].Events));
        conn.FWantclose:=True;
      end;

      if (conn.FParent = Self) and (conn.WantClose) then
      begin
        RemoveSocket(conn);
      end;
    end;
    ThreadTick;
  end;
  j:=High(FSockets);
  while j>=0 do
  begin
    RemoveSocket(FSockets[j]);
    Dec(j);
  end;
end;

procedure TEpollWorkerThread.RemoveSocket(Sock: TEPollSocket;
  doClose: Boolean; doFree: Boolean);
var
  i: Integer;
begin
  for i:=0 to FSocketCount-1 do
  if FSockets[i] = Sock then
  begin
    if epoll_ctl(epollfd, EPOLL_CTL_DEL, FSockets[i].Socket, nil)<0 then
      dolog(llError, 'epoll_ctl_del failed #'+IntToStr(fpgeterrno));

    sock.FParent:=nil;

    Dec(FSocketCount);
    FSockets[i]:=FSockets[FSocketCount];

    if doFree then
    begin
      Sock.Dispose;
    end;
    Exit;
  end;
end;

procedure TEpollWorkerThread.ThreadTick;
var j: Integer;
begin
  inc(Fticks);
  if(FTicks>=ClientTickInterval) then
  begin
    FTicks:=0;
    j:=FSocketCount-1;
    while j>=0 do
    begin
      if (FSockets[j].CheckTimeout)or Terminated then
      begin
        RemoveSocket(FSockets[j]);
        Dec(j, 2);
      end else
        Dec(j);
    end;
  end;
end;

constructor TEpollWorkerThread.Create(aParent: TObject);
begin
  FParent:=aParent;

  if assignpipe(FPipeOutput, FPipeInput)<>0 then
    dolog(llError, 'Could not create pipes for epoll worker thread!');

  inherited Create(False);
end;

destructor TEpollWorkerThread.Destroy;
var
  i: Integer;
begin
  for i:=0 to FSocketCount-1 do
    FSockets[i].Free;
  FSocketCount:=0;
//  FCS.Destroy;
  inherited Destroy;
end;

function TEpollWorkerThread.Callback(Method: TEPollCallbackProc): Boolean;
begin
  result:=FpWrite(FPipeInput, Method, sizeof(Method)) = Sizeof(Method);
end;

function TEpollWorkerThread.AddSocket(Sock: TEPollSocket): Boolean;
var
  event: epoll_event;
begin
  if FSocketCount>=MaxConnectionsPerThread then
  begin
    result:=False;
    Exit;
  end;

  Inc(FTotalCount);
  FSockets[FSocketCount]:=Sock;
  {$IFDEF OPENSSL_SUPPORT}
  if Sock.WantSSL then
  begin
    Sock.StartSSL;
    Sock.WantSSL:=False;
  end;
  {$ENDIF}

  event.Events:=EPOLLIN;
  event.Data.ptr:=Sock;

  if epoll_ctl(epollfd, EPOLL_CTL_ADD, Sock.Socket, @event)<0 then
  begin
    dolog(llDebug, 'epoll_ctl_add failed, error #'+IntTostr(fpgeterrno)+' '+IntToStr(Sock.FSocket));
    result:=False;
  end else
  begin
    Inc(FSocketCount);
    result:=True;

    if Assigned(FOnConnection) then
      FOnConnection(Sock);
  end;
end;

end.

