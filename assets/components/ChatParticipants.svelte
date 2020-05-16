<script>
import Button from '../components/form/Button.svelte';
import Icon from '../components/Icon.svelte';
import Link from '../components/Link.svelte';
import {afterUpdate, getContext} from 'svelte';
import {l} from '../js/i18n';
import {modeClassNames} from '../js/util';

const rtc = getContext('rtc');
const user = getContext('user');

export let dialog;

$: connection = user.findDialog({connection_id: dialog.connection_id});

afterUpdate(() => rtc.render());

function toggleMute(kind) {
  rtc.mute('local', kind);
}

function muteIcon(rtc, kind) {
  const icon = kind == 'video' ? 'video-slash' : 'microphone-slash';
  return rtc.isMuted('local', kind) ? icon : icon.replace(/-slash/, '');
}
</script>

{#if $rtc.localStream.id}
  <div class="rtc-conversations">
    <div class="rtc-conversation is-local has-state-0" class:has-audio-only="{!$rtc.constraints.video}" class:has-video="{$rtc.constraints.video}">
      <video id="{rtc.id($rtc.localStream)}"></video>
      <Icon name="pick:{connection.nick}" family="solid"/>
      <div class="rtc-conversation__info">
        <div>
          {#if $rtc.constraints.video}
            <Button icon="{muteIcon($rtc, 'video')}" on:click="{e => toggleMute('video')}"/>
          {/if}
          <Button icon="{muteIcon($rtc, 'audio')}" on:click="{e => toggleMute('audio')}"/>
        </div>
        <p class="rtc-conversation__name">{connection.nick}</p>
      </div>
    </div>
    {#each $rtc.peerConnections({remoteStream: true}) as pc}
      <div class="rtc-conversation is-remote has-state-0" class:has-audio-only="{!$rtc.constraints.video}" class:has-video="{$rtc.constraints.video}">
        <video id="{rtc.id(pc)}"></video>
        <Icon name="pick:{pc.target.toLowerCase()}" family="solid"/>
        <div class="rtc-conversation__info">
          <div>
            {#if $rtc.constraints.video}
              <Button icon="search-plus"/>
            {:else}
              <Button icon="microphone" disabled="{true}"/>
            {/if}
          </div>
          <p class="rtc-conversation__name">{pc.target}</p>
        </div>
      </div>
    {/each}
  </div>
{/if}

{#if dialog.participants().length}
  <div class="sidebar-right">
    <nav class="sidebar-right__nav">
      <h3>{l('Participants (%1)', dialog.participants().length)}</h3>
      {#each dialog.participants() as participant}
        <Link href="/chat/{dialog.connection_id}/{participant.id}" class="participant {modeClassNames(participant.modes)}">
          <Icon name="pick:{participant.id}" family="solid" color="{participant.color}"/>
          <span>{participant.nick}</span>
        </Link>
      {/each}
    <nav>
  </div>
{/if}
