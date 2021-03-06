{% for q_id, q in m.survey.questions[id] %}
	<li id="{{ q_id }}"> 
	    <p class="survey-info">{{ q.name|escape }}
	        &nbsp; <button class="right" id="{{ #x.q_id }}">x</button><button class="right" id="{{ #e.q_id }}">{_ edit _}</button>
		</p>
		{{ q.html|replace:['class="', 'class="nosubmit '] }}
	</li>
	{% sortable id=q_id tag=q_id%}
	{% wire id=#x.q_id delegate="mod_survey" action={dialog_survey_question_delete id=id question_id=q_id} %}
	{% wire id=#e.q_id delegate="mod_survey" action={dialog_survey_question id=id question_id=q_id} %}
{% empty %}
	<li>
		{_ Drag questions here. _}
	</li>
{% endfor %}
