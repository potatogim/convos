import Reactive from '../js/Reactive';

export default class WebRTCPeerConnection extends Reactive {
  constructor(params) {
    super(params);

    this.prop('ro', 'localStream', params.localStream);
    this.prop('ro', 'peerConfig', params.peerConfig);
    this.prop('ro', 'target', params.target);
    this.prop('rw', 'remoteStream', null);
    this.prop('rw', 'role', '');

    this.signalQueue = [];
  }

  async call() {
    this._throwifStarted();
    this.update({role: 'caller'});
    const pc = this._pc();
    const sdp = await pc.createOffer();
    pc.setLocalDescription(sdp);
    this.emit('signal', {offer: sdp.sdp, target: this.target});
    this._processSignalQueue();
  }

  hangup() {
    if (this.pc) this.pc.close();
    this.update({role: ''});
    this.emit('hangup');
  }

  async info() {
    const stats = this.pc ? await this.pc.getStats(null) : {};

    return {
      iceConnectionState: this.pc && this.pc.iceConnectionState || '',
      iceGatheringState: this.pc && this.pc.iceGatheringState || '',
      signalingState: this.pc && this.pc.signalingState || '',
      ...stats,
    };
  }

  signal(msg) {
    const queueMethod = msg.offer ? 'unshift' : 'push'; // process "SDP offer" before "ice candidate"
    this.signalQueue[queueMethod](msg);
    this._processSignalQueue();
  }

  _onIceCandidate({candidate}) {
    if (!candidate) return;
    this.emit('signal', {ice: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, target: this.target});
  }

  _onTrack({streams, track}) {
    track.onended = (e) => this._todo('onended', e);
    track.onmute = (e) => this._todo('onmute', e);
    track.onunmute = (e) => this._todo('onunmute', e);
    this.update({remoteStream: streams[0] || null});
  }

  _pc() {
    if (this.pc) return this.pc;

    const pc = new RTCPeerConnection(this.peerConfig);
    this.localStream.getTracks().forEach(track => pc.addTrack(track, this.localStream));
    pc.onicecandidate = (e) => this._onIceCandidate(e);
    pc.oniceconnectionstatechange = (e) => this._todo('oniceconnectionstatechange', e);
    pc.onicegatheringstatechange = (e) => this._todo('onicegatheringstatechange', e);
    pc.onremovetrack = (e) => this._todo('onremovetrack', e);
    pc.onsignalingstatechange = (e) => this._todo('onsignalingstatechange', e);
    pc.ontrack = (e) => this._onTrack(e);

    return (this.pc = pc);
  }

  _processSignalQueue() {
    this.signalQueue = this.signalQueue.filter((msg, i) => {
      if (msg.ice) return this._processIceSignalIceCandiate(msg) ? false : true;
      if (msg.answer) return this._processSignalAnswer(msg) ? false : true;
      if (msg.offer) return this._processSignalOffer(msg) ? false : true;
      return false;
    });

    this.signalQueue = [];
  }

  _processSignalAnswer(msg) {
    if (this.pc.signalingState != 'have-local-offer') {
      console.error('[processSignalAnswer] signalingState =', this.pc.signalingState);
      return false;
    }

    this.pc.setRemoteDescription(new RTCSessionDescription({sdp: msg.answer, type: 'answer'}));
    return true;
  }

  _processIceSignalIceCandiate(msg) {
    this.pc.addIceCandidate(new RTCIceCandidate({candidate: msg.ice, sdpMid: msg.sdpMid, sdpMLineIndex: msg.sdpMLineIndex}));
    return true;
  }

  _processSignalOffer(msg) {
    this._throwifStarted();
    this.update({role: 'callee'});

    const pc = this._pc();
    if (pc.signalingState != 'stable') {
      console.error('[processSignalOffer] signalingState =', pc.signalingState);
      return false;
    }

    this.pc.setRemoteDescription(new RTCSessionDescription({sdp: msg.offer, type: 'offer'}));
    pc.createAnswer().then(sdp => {
      pc.setLocalDescription(sdp);
      this.emit('signal', {answer: sdp.sdp, target: this.target});
    });

    return true;
  }

  _throwifStarted() {
    if (this.role) throw '[WebRTCPeerConnection] Already started ' + this.target + ' as ' + this.role;
  }

  _todo(name, e) {
    console.log('TODO: ' + name, e);
  }
}
