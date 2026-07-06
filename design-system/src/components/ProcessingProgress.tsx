import React from 'react';

type Phase = 'uploading' | 'identifying' | 'generating' | 'complete';

const PHASES: Array<{ id: Phase; label: string }> = [
  { id: 'uploading',   label: 'Upload'   },
  { id: 'identifying', label: 'Identify' },
  { id: 'generating',  label: 'Generate' },
  { id: 'complete',    label: 'Done'     },
];

const PHASE_IDX: Record<Phase, number> = {
  uploading: 0, identifying: 1, generating: 2, complete: 3,
};

const PHASE_COPY: Record<Phase, string> = {
  uploading:   'Uploading photos to cloud storage…',
  identifying: 'Gemini is analyzing your item…',
  generating:  'Writing the perfect title & description…',
  complete:    'Your listing is ready to review!',
};

/** AI processing progress shown in the sell flow (mirrors ProcessProgressView) */
export interface ProcessingProgressProps {
  /** Current processing phase */
  phase?: Phase;
  /** Overall progress value 0–1 */
  progress?: number;
  /** Total number of items being processed in this session */
  itemCount?: number;
  /** How many items have finished */
  completedCount?: number;
}

export function ProcessingProgress({
  phase = 'identifying',
  progress = 0.4,
  itemCount = 1,
  completedCount = 0,
}: ProcessingProgressProps) {
  const idx = PHASE_IDX[phase];
  const isDone = phase === 'complete';
  const title = isDone
    ? `${itemCount} item${itemCount !== 1 ? 's' : ''} ready`
    : `Processing ${itemCount} item${itemCount !== 1 ? 's' : ''}…`;

  return (
    <div className="wonni wonni-processing">
      <div className="wonni-processing__icon">
        {isDone ? '✓' : '✦'}
      </div>
      <div className="wonni-processing__title">{title}</div>
      <div className="wonni-processing__subtitle">{PHASE_COPY[phase]}</div>

      <div className="wonni-processing__bar-track">
        <div
          className="wonni-processing__bar-fill"
          style={{ width: `${Math.round(Math.min(1, progress) * 100)}%` }}
        />
      </div>

      <div className="wonni-processing__steps">
        {PHASES.map((p, i) => {
          const stepDone   = i < idx || isDone;
          const stepActive = i === idx && !isDone;
          return (
            <div key={p.id} className="wonni-processing__step">
              <div className={['wonni-processing__step-dot',
                stepActive ? 'wonni-processing__step-dot--active' : '',
                stepDone   ? 'wonni-processing__step-dot--done'   : '',
              ].filter(Boolean).join(' ')} />
              <div className={['wonni-processing__step-label',
                stepActive ? 'wonni-processing__step-label--active' : '',
                stepDone   ? 'wonni-processing__step-label--done'   : '',
              ].filter(Boolean).join(' ')}>
                {p.label}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
